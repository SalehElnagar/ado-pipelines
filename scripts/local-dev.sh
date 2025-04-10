#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=${TAG:-local}
REGISTRY=${REGISTRY:-local}

build() {
  docker build -f "$ROOT_DIR/apps/api-service/Dockerfile" -t "$REGISTRY/api-service:$TAG" "$ROOT_DIR/apps/api-service"
  docker build -f "$ROOT_DIR/apps/worker-service/Dockerfile" -t "$REGISTRY/worker-service:$TAG" "$ROOT_DIR/apps/worker-service"
}

test_images() {
  docker build --target test -f "$ROOT_DIR/apps/api-service/Dockerfile" "$ROOT_DIR/apps/api-service"
  docker build --target test -f "$ROOT_DIR/apps/worker-service/Dockerfile" "$ROOT_DIR/apps/worker-service"
}

run_api() {
  docker run --rm -p 3000:3000 "$REGISTRY/api-service:$TAG"
}

run_worker() {
  docker run --rm -e RUN_WORKER=true "$REGISTRY/worker-service:$TAG"
}

case "${1:-}" in
  build) build ;;
  test) test_images ;;
  run-api) run_api ;;
  run-worker) run_worker ;;
  *)
    echo "Usage: $0 {build|test|run-api|run-worker}" >&2
    exit 1
    ;;
esac
