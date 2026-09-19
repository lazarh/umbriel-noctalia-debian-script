#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME='umbriel-noctalia-install'
readonly PREFIX='/usr/local'
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$SCRIPT_NAME"
readonly LOG_DIR="$STATE_DIR/logs"
readonly SOURCE_DIR="$STATE_DIR/src"
readonly BUILD_DIR="$STATE_DIR/build"

readonly UMBRIEL_REPO='https://github.com/noctalia-dev/umbriel.git'
readonly NOCTALIA_REPO='https://github.com/noctalia-dev/noctalia.git'
readonly SATELLITE_REPO='https://github.com/Supreeeme/xwayland-satellite.git'

readonly NOCTALIA_KEY_URL='https://pkg.noctalia.dev/deb/nickh-archive-keyring.gpg'
readonly NOCTALIA_KEYRING='/usr/share/keyrings/nickh-archive-keyring.gpg'
readonly NOCTALIA_SOURCES_URL='https://pkg.noctalia.dev/deb/noctalia-trixie.sources'

log() { printf '\n==> %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
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
$SCRIPT_NAME - install Umbriel and Noctalia v5 from current upstream sources on Debian 13 (Trixie) amd64

Operations:
  --deps        Install build and runtime dependencies (APT repos, packages; requires libinput >= 1.29)
  --umbriel     Build and install Umbriel (prefix $PREFIX)
  --noctalia    Build and install Noctalia v5 (prefix $PREFIX)
  --all         Run dependencies, then Umbriel, then Noctalia
  --configure   (optional, after --all/--noctalia) generate a first-time Umbriel config
                that autostarts Noctalia; never touches an existing config

Options:
  --with-satellite   Also build the optional xwayland-satellite companion (X11 app
                     support; pulls the Rust toolchain and the Xwayland server)
  -y, --yes          Assume "yes" for prompts
  -h, --help         Show this help

With no operation given, an interactive menu is shown.
Source trees and build directories are retained under $STATE_DIR.
EOF
}

opt_all=0 opt_deps=0 opt_umbriel=0 opt_noctalia=0 opt_configure=0
opt_satellite=0
opt_yes=0

parse_args() {
  while (($#)); do
    case "$1" in
      --deps) opt_deps=1 ;;
      --umbriel) opt_umbriel=1 ;;
      --noctalia) opt_noctalia=1 ;;
      --all) opt_all=1 ;;
      --configure) opt_configure=1 ;;
      --with-satellite) opt_satellite=1 ;;
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

  # Safety gate: dry-run the transaction and refuse if apt proposes removing
  # or downgrading anything. Our installs never legitimately mutate packages
  # outside the requested set; a proposal that does means the host is in a
  # mixed or broken state (foreign suites like testing, half-finished
  # transitions) and executing it could uninstall unrelated software.
  # The dry-run output is retained in the install log on every path.
  local sim
  sim="$(apt-get install -s -y "$@" 2>&1 || true)"
  if grep -qE 'will be (REMOVED|DOWNGRADED)' <<<"$sim"; then
    printf '%s\n' "$sim" | tee -a "$log_file" >&2
    die "apt proposed removing or downgrading packages while: $reason
Refusing to execute. The host's APT state looks mixed or broken. Either:
  sudo apt --fix-broken install   # repair broken dependencies first, or
  disable foreign suites (e.g. 'testing' entries in /etc/apt/sources.list.d/)
  for the duration of this install, then re-run."
  fi
  if grep -q '^E: ' <<<"$sim"; then
    printf '%s\n' "$sim" | tee -a "$log_file" >&2
    die "apt could not resolve: $reason (see simulation above)"
  fi
  printf '%s\n' "$sim" >>"$log_file"

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

deps_preflight() {
  info 'Preflight: base build tooling'
  require_root 'running APT'

  # Self-heal: if the host's sources.list already references trixie-backports
  # but a stale sources.list.d/trixie-backports.list was added by an earlier
  # run, drop the .d/ file so apt stops emitting "Target Packages configured
  # multiple times" warnings.
  if [[ -f /etc/apt/sources.list.d/trixie-backports.list ]] \
    && grep -qE -- '(^| )trixie-backports' /etc/apt/sources.list 2>/dev/null; then
    info 'Removing stale sources.list.d/trixie-backports.list (sources.list already has trixie-backports)'
    sudo rm -f /etc/apt/sources.list.d/trixie-backports.list
  fi

  # Fetch the Noctalia archive keyring to the system location via run_logged
  # so any curl-side error lands in the retained log, then sniff the
  # OpenPGP '99 02' header bytes so an upstream rotation or a bad body can't
  # silently leave a broken keyring behind. This step MUST run before the
  # first apt-get update, otherwise InRelease signatures would never verify.
  info "Fetching Noctalia archive keyring to $NOCTALIA_KEYRING"
  run_logged sudo curl -fsSL "$NOCTALIA_KEY_URL" -o "$NOCTALIA_KEYRING"
  if ! head -c 2 "$NOCTALIA_KEYRING" | od -An -tx1 | tr -d ' \n' | grep -qx '9902'; then
    die "Fetched keyring at $NOCTALIA_KEYRING is not a valid OpenPGP block (missing 99 02 magic bytes)"
  fi

  if [[ ! -f /etc/apt/sources.list.d/noctalia.sources ]]; then
    info 'Adding Noctalia APT repository to /etc/apt/sources.list.d/'
    curl -fsSL "$NOCTALIA_SOURCES_URL" | sudo tee /etc/apt/sources.list.d/noctalia.sources >/dev/null
  fi

  # Noctalia's trixie-backports suite has libdrm/Wayland/xkbcommon that
  # Umbriel+wlroots depend on, but APT would default-pin it at 100 (standard
  # backports priority) and refuse the upgrade against Debian stable. Pin
  # Noctalia origin above Debian stable so its newer packages win.
  local pref='/etc/apt/preferences.d/noctalia.pref'
  if [[ ! -f "$pref" ]]; then
    info 'Pinning Noctalia origin above Debian stable'
    sudo tee "$pref" >/dev/null <<'EOF'
Package: *
Pin: origin "pkg.noctalia.dev"
Pin-Priority: 990
EOF
  fi

  run_logged sudo apt-get update

  if ! command -v curl >/dev/null; then
    info 'Installing curl (required to fetch repositories and sources)'
    apt_install 'installing curl' curl
  fi
}

# APT sources are configured inside deps_preflight, so the keyring is in
# place before the first apt-get update. setup_apt_sources/configure_apt
# used to live here; they're harmless no-ops in case any caller still
# references them.
configure_apt() { :; }
setup_apt_sources() { configure_apt; }

install_noctalia_deps() {
  log 'Installing Noctalia build dependencies'
  # No explicit suite qualifiers: the Noctalia origin pin already prefers the
  # backported versions on a clean trixie host, and a hard qualifier would
  # force a downgrade on hosts that already carry a newer wayland-protocols.
  apt_install 'installing Noctalia build dependencies' \
    meson g++ ninja-build pkg-config \
    libwayland-dev wayland-protocols \
    libegl-dev libgles-dev libfreetype-dev libfontconfig-dev libcairo2-dev \
    libpango1.0-dev libharfbuzz-dev librsvg2-dev libxkbcommon-dev libglib2.0-dev \
    libsecret-1-dev libsodium-dev libsdbus-c++-dev libpipewire-0.3-dev \
    libwireplumber-0.5-dev libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev \
    libwebp-dev libjxl-dev libsndfile1-dev libqalculate-dev \
    libxml2-dev libmd4c-dev libtomlplusplus-dev libical-dev nlohmann-json3-dev \
    libstb-dev libjemalloc-dev
}

install_umbriel_deps() {
  log 'Installing Umbriel build dependencies'
  apt_install 'installing Umbriel build dependencies' \
    meson ninja-build pkg-config build-essential \
    libwayland-bin libwayland-dev wayland-protocols \
    libwlroots-0.20-dev libxkbcommon-dev libpixman-1-dev libtomlplusplus-dev \
    nlohmann-json3-dev libcairo2-dev libpango1.0-dev libdrm-dev libegl-dev \
    libgles-dev libgbm-dev libudev-dev liblcms2-dev libjemalloc-dev \
    libseat-dev libdisplay-info-dev libliftoff-dev hwdata
}

install_runtime_deps() {
  log 'Installing runtime companions for a usable session'
  apt_install 'installing runtime companions' \
    pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-umbriel \
    systemd dbus-user-session fonts-dejavu-core git
}

require_libinput() {
  if pkg_atleast libinput 1.29; then
    return 0
  fi

  die "libinput >=1.29 not found (pkg-config).
Umbriel requires libinput >= 1.29, which Debian 13 stable does not ship.
Install it from Debian 'testing' with these steps:

  1) Add the testing suite as an APT source:
     echo 'deb http://deb.debian.org/debian testing main' \
       | sudo tee /etc/apt/sources.list.d/testing.list

  2) Pin only the libinput package family to testing (everything else
     stays on stable):
     sudo tee /etc/apt/preferences.d/libinput-testing.pref >/dev/null <<'EOF'
     Package: libinput* libevdev* libwacom*
     Pin: release a=testing
     Pin-Priority: 900
     EOF

  3) Refresh and install the development package:
     sudo apt update && sudo apt install libinput-dev

  4) Re-run this script.
"
}

install_deps() {
  deps_preflight
  install_noctalia_deps
  install_umbriel_deps
  install_runtime_deps
  require_libinput
}

clone_upstream_tip() {
  local name="$1" repo="$2"
  local dir="$SOURCE_DIR/$name"
  if [[ ! -d "$dir/.git" ]]; then
    info "Cloning $name"
    mkdir -p "$SOURCE_DIR"
    git clone "$repo" "$dir"
  fi
  pushd "$dir" >/dev/null
  info "Fetching $name upstream"
  git fetch origin
  if [[ -n "$(git status --porcelain)" ]]; then
    die "$name source tree has local modifications; commit or discard them first"
  fi
  local ref
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" \
    && ref="${ref#refs/remotes/origin/}" \
    || ref="main"
  git checkout --detach "origin/$ref"
  info "$name checked out at $(git rev-parse --short HEAD) (origin/$ref tip)"
  popd >/dev/null
  printf '%s' "$dir"
}

meson_build() {
  local name="$1" build="$2" bin="$3"
  shift 3
  mkdir -p "$BUILD_DIR"
  pushd "$SOURCE_DIR/$name" >/dev/null
  local pinfile="$build/.pin" sha
  sha="$(git rev-parse HEAD)"
  if [[ ! -d "$build" ]] || [[ ! -f "$pinfile" ]] || [[ "$(cat "$pinfile")" != "$sha" ]]; then
    rm -rf "$build"
    info "Configuring $name"
    meson setup "$build" --prefix="$PREFIX" --buildtype=release "$@"
    printf '%s' "$sha" >"$pinfile"
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
  clone_upstream_tip umbriel "$UMBRIEL_REPO" >/dev/null
  meson_build umbriel "$BUILD_DIR/umbriel" umbriel -Dtests=disabled
}

build_satellite() {
  ((opt_satellite)) || { info 'Skipping xwayland-satellite (pass --with-satellite for X11 application support)'; return 0; }
  log 'Building optional xwayland-satellite (X11 application support)'
  apt_install 'installing xwayland-satellite build prerequisites' rustc cargo clang libxcb1-dev libxcb-cursor-dev xwayland

  local dir
  dir="$(clone_upstream_tip xwayland-satellite "$SATELLITE_REPO")"
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
  clone_upstream_tip noctalia "$NOCTALIA_REPO" >/dev/null
  meson_build noctalia "$BUILD_DIR/noctalia" noctalia \
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