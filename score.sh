#!/usr/bin/env bash
# score.sh — FROZEN HARNESS. Do not edit.
#
# Builds the current Dockerfile against the repo root, runs the container,
# smoke-tests it, measures size + timing, and prints exactly one final line:
#
#   RESULT=<PASS|FAIL_BUILD|FAIL_BOOT|FAIL_SMOKE> SIZE=<bytes> BUILD_S=<int> TOTAL_S=<int> STARTED=<ISO8601_UTC>
#
# All other output (build logs, container logs) goes above that line.
#
# A machine-readable copy of the result is also written to ./last_run.env
# so the autoresearch driver can `source` it without parsing stdout.
#
# Env knobs:
#   IMAGE_TAG        default: guidezy:autoresearch
#   HOST_PORT        default: 3000
#   CONTAINER_PORT   default: 3000
#   READY_TIMEOUT    default: 60   (passed through to smoke_test.sh)
#   BUILD_NO_CACHE   default: 0    (set 1 to pass --no-cache to docker build)
#   KEEP_CONTAINER   default: 0    (set 1 to leave container running after PASS)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DOCKERFILE="$HERE/Dockerfile"
SMOKE="$HERE/smoke_test.sh"
LAST_RUN="$HERE/last_run.env"
CONFIG="$HERE/config.env"

# Source per-project config if present. Inline env vars still win because we
# only fall back to these defaults below.
if [ -f "$CONFIG" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG"
  set +a
fi

APP_NAME="${APP_NAME:-app}"
IMAGE_TAG="${IMAGE_TAG:-${APP_NAME}:autoresearch}"
HOST_PORT="${HOST_PORT:-3000}"
CONTAINER_PORT="${CONTAINER_PORT:-3000}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"
BUILD_NO_CACHE="${BUILD_NO_CACHE:-0}"
KEEP_CONTAINER="${KEEP_CONTAINER:-0}"

CONTAINER_NAME="${APP_NAME}-autoresearch-$$"

# --- timing helpers ---
script_started_unix=$(date -u +%s)
script_started_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_seconds=0
total_seconds=0

now_unix() { date -u +%s; }

emit() {
  # Final result line. Always last line of stdout. Also writes last_run.env.
  local result="$1" size="$2"
  total_seconds=$(( $(now_unix) - script_started_unix ))
  echo "RESULT=$result SIZE=$size BUILD_S=$build_seconds TOTAL_S=$total_seconds STARTED=$script_started_iso"
  {
    echo "STARTED=$script_started_iso"
    echo "RESULT=$result"
    echo "SIZE=$size"
    echo "BUILD_S=$build_seconds"
    echo "TOTAL_S=$total_seconds"
    echo "DOCKERFILE=$DOCKERFILE"
    echo "IMAGE_TAG=$IMAGE_TAG"
  } > "$LAST_RUN" 2>/dev/null || true
}

cleanup() {
  if [ "$KEEP_CONTAINER" != "1" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- preflight ---

if ! command -v docker >/dev/null 2>&1; then
  echo "score.sh: docker not found on PATH" >&2
  emit FAIL_BUILD 0
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "score.sh: docker daemon is not reachable. Start Docker Desktop (or 'colima start') and retry." >&2
  emit FAIL_BUILD 0
  exit 1
fi

if [ ! -f "$DOCKERFILE" ]; then
  echo "score.sh: Dockerfile missing at $DOCKERFILE" >&2
  emit FAIL_BUILD 0
  exit 1
fi

# Ensure repo root has a .dockerignore so the build context is sane.
# We install one if absent — it's part of the frozen contract, not the experiment.
DOCKERIGNORE_SRC="$HERE/.dockerignore.repo"
DOCKERIGNORE_DST="$REPO_ROOT/.dockerignore"
if [ -f "$DOCKERIGNORE_SRC" ]; then
  if [ ! -f "$DOCKERIGNORE_DST" ] || ! cmp -s "$DOCKERIGNORE_SRC" "$DOCKERIGNORE_DST"; then
    echo "score.sh: installing repo-root .dockerignore from $DOCKERIGNORE_SRC"
    cp "$DOCKERIGNORE_SRC" "$DOCKERIGNORE_DST"
  fi
fi

# --- build ---

BUILD_FLAGS=()
if [ "$BUILD_NO_CACHE" = "1" ]; then
  BUILD_FLAGS+=(--no-cache)
fi

echo "score.sh: [$(date -u +%H:%M:%SZ)] building $IMAGE_TAG (context=$REPO_ROOT, dockerfile=$DOCKERFILE)"
build_started=$(now_unix)
build_log=$(mktemp)
# Empty-array-safe expansion under set -u: ${arr[@]+"${arr[@]}"} expands to nothing when arr has no elements.
# pipefail (set above) makes this pipeline fail if docker build fails.
if ! docker build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} -f "$DOCKERFILE" -t "$IMAGE_TAG" "$REPO_ROOT" 2>&1 | tee "$build_log"; then
  build_seconds=$(( $(now_unix) - build_started ))
  echo "----- last 80 lines of build log -----"
  tail -n 80 "$build_log"
  echo "--------------------------------------"
  rm -f "$build_log"
  echo "score.sh: build FAILED after ${build_seconds}s"
  emit FAIL_BUILD 0
  exit 1
fi
build_seconds=$(( $(now_unix) - build_started ))
rm -f "$build_log"
echo "score.sh: [$(date -u +%H:%M:%SZ)] build OK in ${build_seconds}s"

# --- run ---

# Free the host port if something is already bound — we don't want to mask a real failure
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "score.sh: [$(date -u +%H:%M:%SZ)] starting container $CONTAINER_NAME on host port $HOST_PORT"
if ! docker run -d --name "$CONTAINER_NAME" \
       -p "${HOST_PORT}:${CONTAINER_PORT}" \
       -e PORT="${CONTAINER_PORT}" \
       -e HOSTNAME=0.0.0.0 \
       "$IMAGE_TAG" >/dev/null; then
  echo "score.sh: docker run failed"
  emit FAIL_BOOT 0
  exit 1
fi

# Verify it didn't crash immediately
sleep 1
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
  echo "----- container exited immediately; logs follow -----"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -n 200
  echo "-----------------------------------------------------"
  emit FAIL_BOOT 0
  exit 1
fi

# --- smoke ---

smoke_started=$(now_unix)
SMOKE_HOST=localhost SMOKE_PORT="$HOST_PORT" SMOKE_TIMEOUT="$READY_TIMEOUT" \
  bash "$SMOKE"
smoke_rc=$?
smoke_seconds=$(( $(now_unix) - smoke_started ))
echo "score.sh: [$(date -u +%H:%M:%SZ)] smoke finished in ${smoke_seconds}s (rc=$smoke_rc)"

# --- measure ---

size_bytes=$(docker image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo 0)
size_bytes="${size_bytes:-0}"

if [ "$smoke_rc" -ne 0 ]; then
  echo "----- smoke failed; container logs follow -----"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -n 200
  echo "-----------------------------------------------"
  emit FAIL_SMOKE "$size_bytes"
  exit 1
fi

emit PASS "$size_bytes"
