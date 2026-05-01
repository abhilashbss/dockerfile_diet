#!/usr/bin/env bash
# smoke_test.sh — FROZEN CONTRACT. Do not edit.
#
# Inputs (env):
#   SMOKE_HOST     default: localhost
#   SMOKE_PORT     default: 3000
#   SMOKE_TIMEOUT  default: 60   (seconds to wait for readiness)
#
# Exit codes:
#   0   PASS — GET / returned 200
#   2   FAIL — never became ready, or non-200
set -u

HOST="${SMOKE_HOST:-localhost}"
PORT="${SMOKE_PORT:-3000}"
TIMEOUT="${SMOKE_TIMEOUT:-60}"
URL="http://${HOST}:${PORT}/"

deadline=$(( $(date +%s) + TIMEOUT ))
last_code=""
last_err=""

while [ "$(date +%s)" -lt "$deadline" ]; do
  # -s silent, -o discard body, -w status, --max-time per-request cap, -L follow redirects
  out=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 5 "$URL" 2>&1)
  rc=$?
  last_code="$out"
  if [ "$rc" -eq 0 ] && [ "$out" = "200" ]; then
    echo "smoke: PASS (GET / -> 200)"
    exit 0
  fi
  last_err="curl rc=$rc http=$out"
  sleep 1
done

echo "smoke: FAIL (last: $last_err) after ${TIMEOUT}s"
exit 2
