#!/usr/bin/env bash
#
# Load all four cheese local:dev images into the kind cluster. The kubelet
# inside kind cannot reach your host docker daemon, so every image consumed
# by image.source: local has to be sideloaded with `kind load docker-image`.
#
# Override which images to load:
#   LOAD="cheese-search-ui-local" ./scripts/load-kind-images.sh

set -euo pipefail

: "${KIND_CLUSTER:=kind}"
: "${IMAGE_TAG:=dev}"

LOAD="${LOAD:-cheese-orchestrator-local cheese-database-local cheese-synthongpt-local cheese-search-ui-local}"

for img in ${LOAD}; do
  echo "==> Loading ${img}:${IMAGE_TAG} into kind cluster '${KIND_CLUSTER}'"
  kind load docker-image "${img}:${IMAGE_TAG}" --name "${KIND_CLUSTER}"
done