#!/usr/bin/env bash
#
# docker/test.sh - run the Installer inside a debian:trixie-slim-based
# container, drive each operation, and assert each stage with the verifier.
#
# Invocation:
#   ./docker/test.sh                       # run every stage: deps umbriel noctalia
#   ./docker/test.sh deps                  # one stage
#   ./docker/test.sh deps noctalia         # subset (skips umbriel)
#
# Stages default to: deps, umbriel, noctalia. The harness always drives the
# Installer with default flags, so the standalone xwayland-satellite operation
# (--satellite) is never run here; exercising it is a manual run.
# On any failure the container and its source/build state are retained with
# instructions for inspection; on a fully green run the container is removed
# and the image is kept for faster repeated runs.
#
# Required on the host: amd64; a Docker daemon known to this user; ~10 GB free.
# Expected cost on 8 cores: ~45 min end-to-end (deps ~10 min, umbriel ~10 min,
# noctalia 752 targets ~30 min).

set -Eeuo pipefail

readonly IMG_TAG='umbriel-noctalia-installer-test'
HOST_REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly HOST_REPO_DIR

stages=("$@")
[[ ${#stages[@]} -gt 0 ]] || stages=(deps umbriel noctalia)

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
fail() {
  local msg="$1"
  log "FAIL: $msg"
  if [[ -n "${ctr:-}" ]]; then
    log "Container $ctr is retained for inspection."
    log "  Enter it:                  docker exec -it $ctr bash"
    log "  Installer logs:            ls -la \"\$(docker inspect -f '{{range .Mounts}}{{.Source}}{{end}' $ctr)/home/test/.local/state/umbriel-noctalia-install/logs\""
  fi
  exit 1
}

stage_install_args() {
  case "$1" in
    deps)     printf '%s' '--deps' ;;
    umbriel)  printf '%s' '--umbriel' ;;
    noctalia) printf '%s' '--noctalia' ;;
    *) printf 'ERROR: unknown stage: %s\n' "$1" >&2; return 1 ;;
  esac
}

ctr=''

cleanup() {
  local rc=$?
  if [[ $rc -eq 0 && -n "$ctr" ]]; then
    log "All stages green; removing container $ctr"
    docker rm -f "$ctr" >/dev/null || true
  fi
  exit $rc
}
trap cleanup EXIT

log "Building image $IMG_TAG"
docker image build -f docker/Dockerfile -t "$IMG_TAG" "$HOST_REPO_DIR" \
  || fail 'docker image build failed'

log "Starting test container"
ctr="$(docker run -d --name "umbriel-test-$$-$RANDOM" "$IMG_TAG" sleep infinity)" \
  || fail 'docker run failed'

for stage in "${stages[@]}"; do
  log "=== stage: $stage ==="
  install_args="$(stage_install_args "$stage")" || fail "bad stage: $stage"
  log "install.sh $install_args -y"
  if ! docker exec "$ctr" bash -c "./install.sh $install_args -y"; then
    fail "./install.sh $install_args failed in container"
  fi
  log "verifying stage: $stage"
  if ! docker exec "$ctr" bash -c "./docker/verify-install.sh --stage $stage"; then
    fail "verifier for stage $stage failed"
  fi
done

log "all requested stages passed green"
