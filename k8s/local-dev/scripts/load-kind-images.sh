#!/usr/bin/env bash
#
# Load all four cheese local:dev images into the kind cluster. The kubelet
# inside kind cannot reach your host docker daemon, so every image consumed
# by image.source: local has to be sideloaded with `kind load docker-image`.
#
# Override which images to load:
#   LOAD="cheese-search-ui-local" ./scripts/load-kind-images.sh
#
# cheese-orchestrator-local and cheese-database-local are mandatory: they are
# added back if an override leaves them out.

set -euo pipefail

: "${KIND_CLUSTER:=kind}"
: "${IMAGE_TAG:=dev}"

# cheese-orchestrator and cheese-database are the two components a CHEESE
# deployment cannot run without (see k8s/README.md "Basic setup"). A LOAD
# override may add images but may not drop these two: a kind cluster missing
# either sits in ImagePullBackOff on the images the chart enables by default,
# which is a confusing failure to debug from the pod list.
MANDATORY_IMAGES="cheese-orchestrator-local cheese-database-local"

# Print the given list with any missing mandatory image prepended, and say so on
# stderr — the operator asked for something incomplete and should know it was
# widened rather than wonder why extra images loaded.
ensure_mandatory() {
  local requested="$1" mandatory="$2" missing="" out=""
  local m r found
  for m in $mandatory; do
    found=0
    for r in $requested; do [ "$r" = "$m" ] && found=1 && break; done
    [ "$found" -eq 0 ] && missing="${missing}${m} "
  done
  [ -n "$missing" ] && echo "==> Adding mandatory image(s): ${missing% }" >&2
  out="$missing"
  for r in $requested; do
    case " $out " in *" $r "*) ;; *) out="${out}${r} " ;; esac
  done
  printf '%s' "${out% }"
}

LOAD="${LOAD:-cheese-orchestrator-local cheese-database-local cheese-synthongpt-local cheese-search-ui-local}"
LOAD="$(ensure_mandatory "$LOAD" "$MANDATORY_IMAGES")"

for img in ${LOAD}; do
  echo "==> Loading ${img}:${IMAGE_TAG} into kind cluster '${KIND_CLUSTER}'"
  kind load docker-image "${img}:${IMAGE_TAG}" --name "${KIND_CLUSTER}"
done