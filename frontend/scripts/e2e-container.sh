#!/usr/bin/env bash
# The browser suite against the built image. Usage: frontend/scripts/e2e-container.sh [image]
# Runs the image as Spaces would, read-only and non-root, and removes the container on any exit.
# It only ever touches dawri-e2e and binds 127.0.0.1:7860. The stand-in project needs a server
# of its own, so it stays out of this run. Pass DAWRI_E2E_OUTPUT to move the test output.
set -euo pipefail

IMAGE="${1:-dawri:local}"
NAME=dawri-e2e
PORT=7860
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cleanup
docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp:rw,mode=1777 --user 1000:1000 \
  -p "127.0.0.1:$PORT:7860" "$IMAGE" >/dev/null

deadline=$(( $(date +%s) + 30 ))
until curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/api/health"; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: /api/health did not answer within 30 s"
    docker logs --tail 30 "$NAME" 2>&1 || true
    exit 1
  fi
  sleep 0.5
done

cd "$HERE/.."
DAWRI_E2E_CONTAINER="$NAME" DAWRI_E2E_PORT="$PORT" npm run e2e:container
