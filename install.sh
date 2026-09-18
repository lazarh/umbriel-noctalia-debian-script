#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME='umbriel-noctalia-install'
readonly PREFIX='/usr/local'
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$SCRIPT_NAME"
readonly LOG_DIR="$STATE_DIR/logs"
readonly SOURCE_DIR="$STATE_DIR/src"
readonly BUILD_DIR="$STATE_DIR/build"

readonly UMBRIEL_REPO='https://github.com/noctalia-dev/umbriel.git'
readonly UMBRIEL_COMMIT='76cede129dc3e86bfb1e3a0009829c06618c0fdb'
readonly NOCTALIA_REPO='https://github.com/noctalia-dev/noctalia.git'
readonly NOCTALIA_COMMIT='c7b9197af77ff22bfb9a83c52a95643a1d90ca86'
readonly LIBINPUT_VERSION='1.29.0'
readonly LIBINPUT_URL="https://gitlab.freedesktop.org/libinput/libinput/-/archive/${LIBINPUT_VERSION}/libinput-${LIBINPUT_VERSION}.tar.gz"
readonly SATELLITE_REPO='https://github.com/Supreeeme/xwayland-satellite.git'
readonly SATELLITE_COMMIT='8d135d3b2854b30fd01ea6cd6c27e523dd50a839'

readonly NOCTALIA_KEY_URL='https://pkg.noctalia.dev/gpg.key'
readonly NOCTALIA_KEYRING='/usr/share/keyrings/nickh-archive-keyring.gpg'
readonly NOCTALIA_SOURCES_URL='https://pkg.noctalia.dev/deb/noctalia-trixie.sources'

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

trap 'on_error' ERR
on_error() {
  local status=$?
  printf '\nFAILED at line %s (exit %s).\n' "${BASH_LINENO[0]}" "$status" >&2
  printf 'Retained state and logs: %s\n' "$LOG_DIR" >&2
  printf 'Build and source trees were kept for retry; inspect before re-running.\n' >&2
  exit "$status"
}

usage() {
  cat <<EOF
$SCRIPT_NAME - install Umbriel and Noctalia v5 from pinned sources on Debian 13 (Trixie) amd64

Operations:
  --deps        Install build and runtime dependencies (APT repos, packages, libinput source build)
  --umbriel     Build and install Umbriel at the pinned revision (prefix $PREFIX)
  --noctalia    Build and install Noctalia v5 at the pinned revision (prefix $PREFIX)
  --all         Run dependencies, then Umbriel, then Noctalia
  --configure   (optional, after --all/--noctalia) generate a first-time Umbriel config
                that autostarts Noctalia; never touches an existing config

Options:
  --no-satellite   Do not build the optional xwayland-satellite companion (no X11 app support)
  -y, --yes        Assume "yes" for prompts
  -h, --help       Show this help

With no operation given, an interactive menu is shown.
Source trees and build directories are retained under $STATE_DIR.
EOF
}

opt_all=0 opt_deps=0 opt_umbriel=0 opt_noctalia=0 opt_configure=0
opt_satellite=1
opt_yes=0

parse_args() {
  while (($#)); do
    case "$1" in
      --deps) opt_deps=1 ;;
      --umbriel) opt_umbriel=1 ;;
      --noctalia) opt_noctalia=1 ;;
      --all) opt_all=1 ;;
      --configure) opt_configure=1 ;;
      --no-satellite) opt_satellite=0 ;;
      -y|--yes) opt_yes=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (run --help)" ;;
    esac
    shift
  done
  if ((opt_all)); then opt_deps=1; opt_umbriel=1; opt_noctalia=1; fi
}

confirm() {
  ((opt_yes)) && return 0
  local prompt="$1"
  local reply
  if ! read -r -p "$prompt [y/N] " reply; then
    info 'No input available; assuming no'
    return 1
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

read_menu() {
  local reply
  read -r -p '> ' reply || exit 0
  printf '%s' "$reply"
}

check_os() {
  [[ "$(dpkg --print-architecture)" == 'amd64' ]] || die "only amd64 is supported"
  local id codename
  id="$(. /etc/os-release && printf '%s' "$ID")"
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  [[ "$id" == 'debian' ]] || die "only Debian is supported (found ID=$id)"
  [[ "$codename" == 'trixie' ]] || die "Debian 13 (trixie) is required (found $codename)"
  command -v sudo >/dev/null || die "sudo is required"
  [[ "$(id -u)" != '0' ]] || die "do not run as root; the script elevates only the needed steps"
}

require_root() {
  sudo -p "sudo password (needed for $1): " true || die "sudo unavailable for $1"
}

apt_install() {
  local reason="$1"
  shift
  require_root "$reason"
  run_logged sudo apt-get install -y "$@"
}

run_logged() {
  printf '\n  + %s\n' "$*"
  "$@" 2>&1 | tee -a "$log_file"
}

pkg_atleast() {
  local name="$1" ver="$2"
  if pkg-config --atleast-version="$ver" "$name" 2>/dev/null; then
    info "  $name $(pkg-config --modversion "$name") meets >=$ver"
    return 0
  fi
  return 1
}

setup_apt_sources() {
  log 'Configuring APT sources'
  require_root 'adding APT repositories'

  if [[ ! -f /etc/apt/sources.list.d/trixie-backports.list ]]; then
    info 'Adding Debian trixie-backports (wayland-protocols for Noctalia)'
    echo 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie-backports main' |
      sudo tee /etc/apt/sources.list.d/trixie-backports.list >/dev/null
  fi

  if [[ ! -f "$NOCTALIA_KEYRING" ]]; then
    info 'Installing Noctalia repository signing key'
    curl -fsSL "$NOCTALIA_KEY_URL" | sudo gpg --batch --yes --dearmor -o "$NOCTALIA_KEYRING"
  fi

  if [[ ! -f /etc/apt/sources.list.d/noctalia.sources ]]; then
    info 'Adding Noctalia APT repository (wlroots 0.20, Wayland, libdrm, xkbcommon backports)'
    curl -fsSL "$NOCTALIA_SOURCES_URL" | sudo tee /etc/apt/sources.list.d/noctalia.sources >/dev/null
  fi

  sudo apt-get update
}

install_noctalia_deps() {
  log 'Installing Noctalia build dependencies'
  apt_install 'installing Noctalia build dependencies' \
    meson g++ ninja-build pkg-config \
    libwayland-dev wayland-protocols/trixie-backports \
    libegl-dev libgles-dev libfreetype-dev libfontconfig-dev libcairo2-dev \
    libpango1.0-dev libharfbuzz-dev librsvg2-dev libxkbcommon-dev libglib2.0-dev \
    libsecret-1-dev libsodium-dev libsdbus-c++-dev libpipewire-0.3-dev \
    libwireplumber-0.5-dev libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev \
    libcurl4-openssl-dev libwebp-dev libjxl-dev libsndfile1-dev libqalculate-dev \
    libxml2-dev libmd4c-dev libtomlplusplus-dev libical-dev nlohmann-json3-dev \
    libstb-dev libjemalloc-dev
}

install_umbriel_deps() {
  log 'Installing Umbriel build dependencies'
  apt_install 'installing Umbriel build dependencies' \
    meson ninja-build pkg-config build-essential \
    libwayland-bin libwayland-dev wayland-protocols/trixie-backports \
    libwlroots-0.20-dev libxkbcommon-dev libpixman-1-dev libtomlplusplus-dev \
    nlohmann-json3-dev libcairo2-dev libpango1.0-dev libdrm-dev libegl-dev \
    libgles-dev libgbm-dev libudev-dev liblcms2-dev libjemalloc-dev \
    libseat-dev libdisplay-info-dev libliftoff-dev hwdata
}

install_runtime_deps() {
  log 'Installing runtime companions for a usable session'
  apt_install 'installing runtime companions' \
    pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-umbriel \
    systemd dbus-user-session xwayland fonts-dejavu-core git
}

install_libinput() {
  if pkg_atleast libinput 1.29; then
    info 'libinput >=1.29 already available'
    return 0
  fi

  log 'Building libinput >=1.29 from source (required by pinned Umbriel, absent from Debian repos)'
  apt_install 'installing libinput build prerequisites' libudev-dev libevdev-dev libmtdev-dev libwacom-dev

  local dir="$SOURCE_DIR/libinput-$LIBINPUT_VERSION"
  if [[ ! -d "$dir" ]]; then
    info 'Fetching libinput source'
    mkdir -p "$SOURCE_DIR"
    curl -fsSL "$LIBINPUT_URL" -o "$SOURCE_DIR/libinput.tar.gz"
    tar -xzf "$SOURCE_DIR/libinput.tar.gz" -C "$SOURCE_DIR"
    rm -f "$SOURCE_DIR/libinput.tar.gz"
  fi

  pushd "$dir" >/dev/null
  if [[ ! -d build ]]; then
    info 'Configuring libinput'
    meson setup build --prefix="$PREFIX" --buildtype=release -Dtests=false -Ddocumentation=false -Ddebug-gui=false
  fi
  info 'Compiling libinput'
  run_logged meson compile -C build
  info 'Installing libinput (system-wide)'
  run_logged sudo meson install -C build
  sudo ldconfig
  popd >/dev/null

  pkg_atleast libinput 1.29 || die 'libinput source build did not satisfy >=1.29'
}

deps_preflight() {
  info 'Preflight: base build tooling'
  require_root 'running APT'
  if ! command -v curl >/dev/null; then
    info 'Installing curl (required to fetch repositories and sources)'
    apt_install 'installing curl' curl
  fi
}

install_deps() {
  deps_preflight
  setup_apt_sources
  install_noctalia_deps
  install_umbriel_deps
  install_runtime_deps
  install_libinput
}

clone_pinned() {
  local name="$1" repo="$2" commit="$3"
  local dir="$SOURCE_DIR/$name"
  if [[ ! -d "$dir/.git" ]]; then
    info "Cloning $name"
    mkdir -p "$SOURCE_DIR"
    git clone "$repo" "$dir"
  fi
  pushd "$dir" >/dev/null
  if ! git rev-parse --verify -q "$commit^{commit}" >/dev/null; then
    git fetch origin "$commit"
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    die "$name source tree has local modifications; commit or discard them first"
  fi
  git checkout --detach "$commit"
  local head want
  head="$(git rev-parse HEAD)"
  want="$(git rev-parse "$commit^{commit}")"
  [[ "$head" == "$want" ]] || die "$name checkout is $head, expected $want"
  popd >/dev/null
  printf '%s' "$dir"
}

meson_build() {
  local name="$1" commit="$2" build="$3" bin="$4"
  shift 4
  mkdir -p "$BUILD_DIR"
  pushd "$SOURCE_DIR/$name" >/dev/null
  local pinfile="$build/.pin"
  if [[ ! -d "$build" ]] || [[ ! -f "$pinfile" ]] || [[ "$(cat "$pinfile")" != "$commit" ]]; then
    rm -rf "$build"
    info "Configuring $name"
    meson setup "$build" --prefix="$PREFIX" --buildtype=release "$@"
    printf '%s' "$commit" >"$pinfile"
  fi
  info "Compiling $name"
  run_logged meson compile -C "$build"
  info "Installing $name"
  require_root "installing $name to /usr/local"
  run_logged sudo meson install -C "$build"
  popd >/dev/null

  command -v "$bin" >/dev/null || die "$bin binary not found after install"
  info "Installed: $(command -v "$bin")"
}

umbriel_preflight() {
  log 'Umbriel preflight'
  pkg_atleast wlroots-0.20 0.20.1 || die 'wlroots 0.20 missing (run --deps)'
  pkg_atleast wayland-server 1.24 || die 'wayland-server >=1.24 missing (run --deps)'
  pkg_atleast wayland-protocols 1.47 || die 'wayland-protocols >=1.47 missing (run --deps)'
  pkg_atleast libdrm 2.4.129 || die 'libdrm >=2.4.129 missing (run --deps)'
  pkg_atleast libinput 1.29 || die 'libinput >=1.29 missing (run --deps)'
}

build_umbriel() {
  umbriel_preflight
  clone_pinned umbriel "$UMBRIEL_REPO" "$UMBRIEL_COMMIT" >/dev/null
  meson_build umbriel "$UMBRIEL_COMMIT" "$BUILD_DIR/umbriel" umbriel -Dtests=disabled
}

build_satellite() {
  ((opt_satellite)) || { info 'Skipping xwayland-satellite (--no-satellite)'; return 0; }
  log 'Building optional xwayland-satellite (X11 application support)'
  apt_install 'installing xwayland-satellite build prerequisites' rustc cargo clang libxcb1-dev libxcb-cursor-dev

  local dir
  dir="$(clone_pinned xwayland-satellite "$SATELLITE_REPO" "$SATELLITE_COMMIT")"
  pushd "$dir" >/dev/null
  info 'Compiling xwayland-satellite (release)'
  cargo build --release
  info 'Installing xwayland-satellite'
  run_logged sudo install -Dm755 target/release/xwayland-satellite "$PREFIX/bin/xwayland-satellite"
  popd >/dev/null
  command -v xwayland-satellite >/dev/null || die 'xwayland-satellite not on PATH after install'
}

build_noctalia() {
  log 'Noctalia preflight'
  pkg_atleast wayland-protocols 1.45 || die 'wayland-protocols >=1.45 missing (run --deps)'
  clone_pinned noctalia "$NOCTALIA_REPO" "$NOCTALIA_COMMIT" >/dev/null
  meson_build noctalia "$NOCTALIA_COMMIT" "$BUILD_DIR/noctalia" noctalia \
    -Dtests=disabled -Dnative_optimizations=false -Djemalloc=auto
}

configure_noctalia_autostart() {
  local cfg="$HOME/.config/umbriel/config.toml"
  if [[ -e "$cfg" ]]; then
    info "Existing config at $cfg left untouched."
    info 'To autostart Noctalia, add "noctalia" to the [general] autostart array.'
    return 0
  fi
  confirm 'No Umbriel config found. Create one that autostarts Noctalia?' || {
    info 'Skipped; Noctalia can be started manually with: noctalia'
    return 0
  }
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<EOF
[general]
autostart = ["noctalia"]
EOF
  info "Wrote starter config to $cfg"
}

menu() {
  while true; do
    cat <<EOF
Choose an operation:
  1) Install dependencies
  2) Install Umbriel
  3) Install Noctalia
  4) Install dependencies + Umbriel + Noctalia
  5) Quit
EOF
    local reply
    reply="$(read_menu)"
    case "$reply" in
      1) opt_deps=1 ;;
      2) opt_umbriel=1 ;;
      3) opt_noctalia=1 ;;
      4) opt_deps=1; opt_umbriel=1; opt_noctalia=1 ;;
      5) exit 0 ;;
      *) info 'Invalid choice'; continue ;;
    esac
    break
  done
}

main() {
  parse_args "$@"
  check_os

  mkdir -p "$LOG_DIR"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  log_file="$LOG_DIR/install-$ts.log"
  info "Log: $log_file"

  if ! ((opt_deps || opt_umbriel || opt_noctalia)); then
    menu
  fi

  if ((opt_deps)); then install_deps; fi
  if ((opt_umbriel)); then build_umbriel; build_satellite; fi
  if ((opt_noctalia)); then build_noctalia; fi
  if ((opt_configure)); then configure_noctalia_autostart; fi

  if ((opt_deps || opt_umbriel || opt_noctalia)); then
    printf '\nDone. Session entries: %s/share/wayland-sessions/\n' "$PREFIX"
    info 'Log retained at: '"$log_file"
  fi
}

main "$@"