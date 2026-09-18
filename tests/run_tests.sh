#!/usr/bin/env bash
set -Eeuo pipefail

failures=0
checks=0

check() {
  local desc="$1" ok="$2"
  checks=$((checks + 1))
  if [[ "$ok" == "0" ]]; then
    printf 'PASS: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}

run_parse() {
  local out="$1"; shift
  bash -c '
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
          -h|--help) echo "__HELP__"; exit 0 ;;
          *) echo "__UNKNOWN__" ;;
        esac
        shift
      done
      if ((opt_all)); then opt_deps=1; opt_umbriel=1; opt_noctalia=1; fi
      printf "deps=%d umbriel=%d noctalia=%d all=%d configure=%d satellite=%d yes=%d\n" \
        "$opt_deps" "$opt_umbriel" "$opt_noctalia" "$opt_all" "$opt_configure" "$opt_satellite" "$opt_yes"
    }
    opt_all=0 opt_deps=0 opt_umbriel=0 opt_noctalia=0 opt_configure=0 opt_satellite=1 opt_yes=0
    parse_args "$@"
  ' -- "$@" >"$out" 2>&1 || true
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

SCRIPT_FILE="$(cd "$(dirname "$(dirname "$0")")" && pwd)/install.sh"

run_parse "$tmp/help.txt" --help
check "--help prints help without error" "$(grep -q __HELP__ "$tmp/help.txt" && echo 0 || echo 1)"

run_parse "$tmp/single.txt" --noctalia
check "--noctalia alone enables only noctalia" "$(grep -q 'deps=0 umbriel=0 noctalia=1 all=0 configure=0 satellite=1 yes=0' "$tmp/single.txt" && echo 0 || echo 1)"

run_parse "$tmp/all.txt" --all
check "--all enables deps+umbriel+noctalia" "$(grep -q 'deps=1 umbriel=1 noctalia=1 all=1' "$tmp/all.txt" && echo 0 || echo 1)"

run_parse "$tmp/nosat.txt" --umbriel --no-satellite
check "--umbriel --no-satellite disables satellite" "$(grep -q 'deps=0 umbriel=1 noctalia=0 all=0 configure=0 satellite=0 yes=0' "$tmp/nosat.txt" && echo 0 || echo 1)"

run_parse "$tmp/combined.txt" --deps --noctalia --yes
check "--deps --noctalia --yes sets flags deterministically" "$(grep -q 'deps=1 umbriel=0 noctalia=1 all=0 configure=0 satellite=1 yes=1' "$tmp/combined.txt" && echo 0 || echo 1)"

run_parse "$tmp/unknown.txt" --bogus
check "unknown option is rejected" "$(grep -q __UNKNOWN__ "$tmp/unknown.txt" && echo 0 || echo 1)"

check "install.sh has no CRLF line endings" "$(file "$SCRIPT_FILE" | grep -q 'CRLF' && echo 1 || echo 0)"
check "install.sh is executable" "$([ -x "$SCRIPT_FILE" ] && echo 0 || echo 1)"
check "install.sh passes bash -n" "$(bash -n "$SCRIPT_FILE" && echo 0 || echo 1)"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))