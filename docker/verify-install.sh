#!/usr/bin/env bash
#
# docker/verify-install.sh - assert the Installer's staged output inside the
# test container. Exits non-zero on any failure.
#
# Stages:
#   deps     libinput >=1.29 visible to pkg-config, xdg-desktop-portal-umbriel
#            installed, wayland-protocols >= 1.47.
#   umbriel  the nine files from the Umbriel build contract under PREFIX,
#            plus the xwayland-satellite companion binary.
#   noctalia Noctalia binary, non-empty assets tree, desktop entry, icon,
#            and `noctalia --version` reporting v5.1.0.

set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local}"
STAGE=''

err() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }
ok()  { printf '  ok:   %s\n' "$*"; }
hdr() { printf '\n[%s]\n' "$STAGE"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --stage) STAGE="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'usage: %s --stage deps|umbriel|noctalia\n' "$0"
        return 0 ;;
      *) printf 'unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$STAGE" ]]; then
    printf 'ERROR: --stage is required\n' >&2
    return 2
  fi
  case "$STAGE" in
    deps|umbriel|noctalia) ;;
    *) printf 'ERROR: --stage must be deps|umbriel|noctalia (got: %s)\n' "$STAGE" >&2; return 2 ;;
  esac
}

ver_atleast() {
  local current="$1" required="$2"
  [[ -n "$current" ]] || return 1
  printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1 | grep -qx "$required"
}

file_or_die() {
  if [[ -e "$1" ]]; then
    ok "exists: $1"
  else
    err "missing: $1"
  fi
}

check_deps() {
  hdr
  local libinput_ver wp_ver wp_stripped
  libinput_ver="$(pkg-config --modversion libinput 2>/dev/null || true)"
  if ver_atleast "$libinput_ver" "1.29.0"; then
    ok "libinput $libinput_ver >= 1.29.0"
  else
    err "libinput ${libinput_ver:-<unknown>} < 1.29.0"
  fi

  if dpkg -s xdg-desktop-portal-umbriel >/dev/null 2>&1; then
    ok "xdg-desktop-portal-umbriel installed"
  else
    err "xdg-desktop-portal-umbriel not installed"
  fi

  wp_ver="$(dpkg-query -W -f='${Version}' wayland-protocols 2>/dev/null || true)"
  wp_stripped="${wp_ver%%-*}"
  if ver_atleast "$wp_stripped" "1.47"; then
    ok "wayland-protocols ${wp_ver} >= 1.47"
  else
    err "wayland-protocols ${wp_ver:-<unknown>} < 1.47"
  fi
}

check_umbriel() {
  hdr
  file_or_die "$PREFIX/bin/umbriel"
  file_or_die "$PREFIX/bin/start-umbriel"
  file_or_die "$PREFIX/share/wayland-sessions/umbriel.desktop"
  file_or_die "$PREFIX/lib/systemd/user/umbriel.service"
  file_or_die "$PREFIX/lib/systemd/user/umbriel-session.target"
  file_or_die "$PREFIX/lib/systemd/user/umbriel-shutdown.target"
  file_or_die "$PREFIX/share/umbriel/config.toml"
  file_or_die "$PREFIX/share/umbriel/shaders/reveal.glsl"
  file_or_die "$PREFIX/share/umbriel/shaders/squash.glsl"
  file_or_die "$PREFIX/bin/xwayland-satellite"
}

check_noctalia() {
  hdr
  local assets ver_out
  if [[ -x "$PREFIX/bin/noctalia" ]]; then
    ok "exec: $PREFIX/bin/noctalia"
  else
    err "missing or not executable: $PREFIX/bin/noctalia"
  fi
  assets="$PREFIX/share/noctalia/assets"
  if [[ -d "$assets" ]] && [[ -n "$(ls -A "$assets" 2>/dev/null || true)" ]]; then
    ok "assets tree non-empty: $assets"
  else
    err "assets tree empty or missing: $assets"
  fi
  file_or_die "$PREFIX/share/applications/dev.noctalia.Noctalia.desktop"
  file_or_die "$PREFIX/share/icons/hicolor/scalable/apps/noctalia.svg"

  XDG_DATA_DIRS="${XDG_DATA_DIRS:-$PREFIX/share:/usr/share}" \
    ver_out="$("$PREFIX/bin/noctalia" --version 2>&1 || true)"
  if [[ "$ver_out" == *5.1.0* ]]; then
    ok "noctalia --version: $ver_out"
  else
    err "noctalia --version did not report 5.1.0: $ver_out"
  fi
}

main() {
  parse_args "$@" || exit $?
  case "$STAGE" in
    deps)     check_deps    ;;
    umbriel)  check_umbriel ;;
    noctalia) check_noctalia ;;
  esac
  printf '\n[verified] %s stage assertions all green\n' "$STAGE"
}

main "$@"
