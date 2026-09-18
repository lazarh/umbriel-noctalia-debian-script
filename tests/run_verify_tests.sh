#!/usr/bin/env bash
#
# tests/run_verify_tests.sh - pre-agreed seam for docker/verify-install.sh:
# guarded checks that exercise its argument handling without needing a
# Debian container or stub fixtures. The full per-stage contract is exercised
# by docker/test.sh; this harness guarantees the surface is wired correctly.

set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VER="$ROOT/docker/verify-install.sh"

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

check "verify-install.sh is executable" \
  "$([[ -x "$VER" ]] && echo 0 || echo 1)"

check "verify-install.sh has no CRLF line endings" \
  "$(file "$VER" | grep -q 'CRLF' && echo 1 || echo 0)"

check "verify-install.sh passes bash -n" \
  "$(bash -n "$VER" && echo 0 || echo 1)"

if bash "$VER" --help >/dev/null 2>&1; then
  ok=0
else
  ok=1
fi
check "--help exits 0" "$ok"

help_out="$(bash "$VER" --help 2>&1 || true)"
check "--help mentions --stage" \
  "$(grep -q -- '--stage' <<<"$help_out" && echo 0 || echo 1)"

if bash "$VER" 2>/dev/null; then
  ok=1
else
  ok=0
fi
check "missing --stage errors" "$ok"

if bash "$VER" --stage bogus 2>/dev/null; then
  ok=1
else
  ok=0
fi
check "unknown --stage errors" "$ok"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
