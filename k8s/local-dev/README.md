# local-dev — kind test harness

Everything in this directory exists to run the `../charts/cheese` chart on a
**throwaway local [kind](https://kind.sigs.k8s.io/) cluster** — for chart
development, source-image iteration, and pre-release smoke tests.

> **Deploying CHEESE to a real cluster?** You do not need anything in here.
> Start at [../README.md](../README.md) — the chart itself has no dependency
> on these files.

## Contents

| Path | What it is |
|---|---|
| `scripts/install-ingress-controller.sh` | label the kind node + install ingress-nginx + wait for rollout |
| `scripts/build-source-images.sh` | rebuild `<svc>-local:dev` images from the upstream source repos |
| `scripts/load-kind-images.sh` | sideload those images into the kind node (`kind load docker-image`) |
| `kind/cluster.yaml` | single-node kind cluster, host ports 80/443 mapped to the ingress |
| `env/cheese-search-ui.build.env.example` | Vite build args baked into a source-built UI bundle |
| `docs/install-order.md` | step-by-step kind install playbook |
| `docs/kind-bringup-log.md` | annotated log of a real first bring-up (gotchas included) |
| `cheese-api-demo.ipynb` | notebook driving the search API for smoke tests |
| `*.local.sh`, `kind/cluster.local.yaml` | machine-specific bring-up scripts — gitignored, never committed |

All script invocations below run from **this directory** (the scripts
themselves are cwd-independent).

## Quick start

```bash
# 1. Cluster + ingress controller
kind create cluster --config kind/cluster.yaml
./scripts/install-ingress-controller.sh

# 2–4. Data staging, images, secrets, helm install — follow the main
#      quick start in ../README.md (run its commands from k8s/).
```

On kind the PV's `hostPath: /data` resolves *inside* the `kind-control-plane`
Docker container, so data is staged with `docker cp … kind-control-plane:/data/…`
— see [../docs/pvc-data-runbook.md](../docs/pvc-data-runbook.md).

## Building images from source

Only needed when iterating on a component. For plain installs leave the chart
default `image.source: acr` and skip this — kubelet pulls the released images
directly.

```bash
cp env/cheese-search-ui.build.env.example env/cheese-search-ui.build.env
$EDITOR env/cheese-search-ui.build.env    # SUPABASE_URL / SUPABASE_ANON_KEY etc.

./scripts/build-source-images.sh          # docker build from ../../../<repo>
./scripts/load-kind-images.sh             # kind cannot see your docker daemon — sideload

# Iterate on a single component:
BUILD="cheese-orchestrator" ./scripts/build-source-images.sh
LOAD="cheese-orchestrator-local" ./scripts/load-kind-images.sh
kubectl -n cheese rollout restart deploy/cheese-orchestrator
```

The upstream repos (`cheese-orchestrator`, `cheese-database`, `cheese-search-ui`,
`synthongpt-prod`) are expected as **siblings of the `cheese-on-prem` checkout**;
override with `SOURCES_ROOT=/path/to/repos` if they live elsewhere. Then flip
`image.source: local` in your values for the components you rebuilt.

## License on kind

The license is keyed to the host hardware of the node running the database
container — on kind that is the `kind-control-plane` container:

```bash
kubectl run -n cheese cheese-license-keygen --rm -it --restart=Never \
  --image=cheese-database-local:dev --image-pull-policy=IfNotPresent \
  --command -- python -c 'from generate_license_ID import main; main()'

# after support returns the license file:
docker cp cheese_license_file.json kind-control-plane:/data/cheese_license_file.json
docker exec kind-control-plane chown 2112:0 /data/cheese_license_file.json
```

Note kind fakes the DMI `product_name` (reads as `kind`), which an on-prem
license bound to the real host will reject — restoring the host value needs an
ephemeral node-level bind mount after every cluster (re)create:

```bash
docker exec kind-control-plane sh -c \
  "printf '%s\n' \"$(cat /sys/devices/virtual/dmi/id/product_name)\" > /tmp/product_name && \
   mount --bind /tmp/product_name /sys/devices/virtual/dmi/id/product_name"
```

## Teardown

```bash
helm uninstall cheese -n cheese
docker exec kind-control-plane rm -rf /data   # destroys the node-local data
kind delete cluster
```
