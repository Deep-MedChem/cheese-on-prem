#!/usr/bin/env bash
#
# Rebuild the four <svc>-local:dev images from upstream source. Use this
# only when you actually need to iterate on the components — for plain
# deploys, leave image.source: acr (the chart default) and let kubelet pull
# cheese.azurecr.io/.../cheese-customer:latest directly.
#
# All four runtime images live in cheese.azurecr.io/on-prem/<svc>/cheese-customer
# — that's what kubelet pulls when image.source: acr. The detail this script
# cares about is the Dockerfile FROM line for local rebuilds:
#   - cheese-orchestrator/Dockerfile-on-prem: FROM cheese.azurecr.io/...:base
#   - cheese-database/Dockerfile-on-prem:     FROM cheese.azurecr.io/...:base
#   - synthongpt-prod/Dockerfile:             FROM public Docker Hub
#   - cheese-search-ui/Dockerfile:            FROM public Docker Hub
# So rebuilding orchestrator/database needs `docker login cheese.azurecr.io`
# (preflight below). synthongpt/search-ui build without ACR auth.
#
# Override which components to build:
#   BUILD="cheese-search-ui" ./scripts/build-source-images.sh
#   BUILD="cheese-orchestrator cheese-database" ./scripts/build-source-images.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${REPO_DIR}/.." && pwd)"

BUILD="${BUILD:-cheese-orchestrator cheese-database cheese-synthongpt cheese-search-ui}"

# Fail fast if we're about to build a service whose Dockerfile bases on
# cheese.azurecr.io but the user can't reach/authenticate to that registry.
# A bare `docker build` would only fail mid-way with an opaque pull error.
preflight_acr_auth() {
  local probe="cheese.azurecr.io/cheese-orchestrator:base"
  if docker manifest inspect "${probe}" >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<EOF
==> ERROR: cannot reach ${probe}.

This script rebuilds <svc>-local:dev images from source. The on-prem
Dockerfiles for cheese-orchestrator and cheese-database inherit FROM
cheese.azurecr.io base images, so docker build needs network access and
credentials for cheese.azurecr.io. Try:

    docker login cheese.azurecr.io

If you don't need to rebuild from source, you don't need this script —
the chart now defaults to image.source: acr. Apply the image-pull-secret
(manifests/base/image-pull-secret.yaml) and helm install: kubelet pulls
cheese.azurecr.io/on-prem/<svc>/cheese-customer:latest directly when pods
schedule. See docs/install-order.md §2.

If you only want to build the components that don't need ACR (synthongpt,
search-ui), re-run with:
    BUILD="cheese-synthongpt cheese-search-ui" $0
EOF
  exit 1
}

for svc in ${BUILD}; do
  case "${svc}" in
    cheese-orchestrator|cheese-database) preflight_acr_auth; break ;;
  esac
done

# Source <env_file>; fall back to <env_file>.example with a warning.
load_env() {
  local env_file="$1"
  local example="${env_file}.example"
  if [[ -f "${env_file}" ]]; then
    set -a; source "${env_file}"; set +a
  elif [[ -f "${example}" ]]; then
    echo "${env_file} not found — using ${example} defaults." >&2
    set -a; source "${example}"; set +a
  else
    echo "Missing ${env_file} and ${example}" >&2
    exit 1
  fi
}

build_search_ui() (
  load_env "${REPO_DIR}/env/cheese-search-ui.build.env"

  : "${IMAGE_NAME:=cheese-search-ui-local}"
  : "${IMAGE_TAG:=dev}"
  : "${LOCAL:=True}"
  : "${CDN_BASE_URL:=}"
  : "${CDN_ENABLED:=false}"
  : "${SUPABASE_URL:=}"
  : "${SUPABASE_ANON_KEY:=}"

  # On-prem-correct defaults for the feature gates. The Dockerfile's own ARG
  # defaults disagree on STRIPE/NOTIFICATIONS, so we set them explicitly here.
  # TODO(after upstream UI refactor): drop these once flags become runtime env.
  : "${ENABLE_ANALYTICS:=false}"
  : "${ENABLE_AUTH:=true}"
  : "${ENABLE_TRACKING:=true}"
  : "${ENABLE_STRIPE:=false}"
  : "${ENABLE_NOTIFICATIONS:=false}"

  echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG}"
  docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f "${PROJECT_ROOT}/cheese-search-ui/Dockerfile" \
    --build-arg LOCAL="${LOCAL}" \
    --build-arg CDN_BASE_URL="${CDN_BASE_URL}" \
    --build-arg CDN_ENABLED="${CDN_ENABLED}" \
    --build-arg SUPABASE_URL="${SUPABASE_URL}" \
    --build-arg SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY}" \
    --build-arg ENABLE_ANALYTICS="${ENABLE_ANALYTICS}" \
    --build-arg ENABLE_AUTH="${ENABLE_AUTH}" \
    --build-arg ENABLE_TRACKING="${ENABLE_TRACKING}" \
    --build-arg ENABLE_STRIPE="${ENABLE_STRIPE}" \
    --build-arg ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS}" \
    "${PROJECT_ROOT}/cheese-search-ui"
)

build_backend() (
  local svc="$1"
  local context dockerfile
  case "${svc}" in
    cheese-orchestrator|cheese-database)
      context="${PROJECT_ROOT}/${svc}"
      dockerfile="${context}/Dockerfile-on-prem"
      ;;
    cheese-synthongpt)
      # Upstream repo and Dockerfile don't follow the on-prem naming convention.
      context="${PROJECT_ROOT}/synthongpt-prod"
      dockerfile="${context}/Dockerfile"
      ;;
  esac

  echo "==> Building ${svc}-local:dev"
  docker build -t "${svc}-local:dev" -f "${dockerfile}" "${context}"
)

for svc in ${BUILD}; do
  case "${svc}" in
    cheese-search-ui) build_search_ui ;;
    cheese-orchestrator|cheese-database|cheese-synthongpt) build_backend "${svc}" ;;
    *) echo "Unknown component: ${svc}" >&2; exit 1 ;;
  esac
done