# Playbook — install order

> **⚠️ Updated flow (chart v0.3.0).** The install is now driven by a single
> `values.yaml` + `deployment.target` (no `values-onprem.yaml`/`values-headless.yaml`
> overlays), and the chart now creates the PV/PVC itself (no manual
> `kubectl apply -f manifests/base/persistent-volume*`). See **[../README.md](../README.md)**
> for the current quick-start and profiles; the data-staging and license steps
> below remain accurate.

End-to-end install of the on-prem prototype on a fresh kind cluster. Steps run
top to bottom; do not skip ahead. For data placement on the PVC, see
[`pvc-data-runbook.md`](./pvc-data-runbook.md).

All paths are relative to the `cheese-k8s/` directory. Run every command from
inside it unless noted otherwise.

There is one Helm chart (`charts/cheese`); a single `helm install` brings up
the whole stack. To skip a component, set its `<component>.enabled: false` in
`values-onprem.yaml`. Common case: `synthongpt: { enabled: false }` if
SynthonGPT is not part of the install — only `/search` and `/database_info`
calls that hit SynthonGPT are affected.

## 0. Prerequisites

- Docker
- `kind` ≥ 0.20
- `kubectl` ≥ 1.28
- `helm` ≥ 3.14 (also works on v4)
- The four upstream repos cloned as siblings of `cheese-k8s/` — i.e. at
  `../cheese-orchestrator`, `../cheese-database`, `../cheese-search-ui`,
  `../synthongpt-prod` when viewed from inside `cheese-k8s/`.

## 1. Cluster + ingress controller

```bash
kind create cluster --config kind/cluster.yaml
make install-ingress-controller
```

This labels the kind node `ingress-ready=true`, installs ingress-nginx, and
waits for the controller to roll out.

## 2. Namespace + PVC

```bash
kubectl apply -f manifests/base/namespace.yaml
kubectl apply -f manifests/base/persistent-volume.local-example.yaml
kubectl apply -f manifests/base/persistent-volume-claim.yaml

kubectl -n cheese get pvc cheese-data-pvc          # STATUS: Bound
```

If `image.source: acr` for any component, also apply the pull secret (after
filling in real credentials):

```bash
cp  manifests/base/image-pull-secret.example.yaml \
    manifests/base/image-pull-secret.yaml
$EDITOR manifests/base/image-pull-secret.yaml
kubectl apply -f manifests/base/image-pull-secret.yaml
```

## 3. Stage data on the PVC

Required before any data-plane pod starts. Follow
[`pvc-data-runbook.md`](./pvc-data-runbook.md) sections 1–3:

- license file at `/data/cheese_license_file.json`
- per-database directories under `/data/<db_name>/`
- SynthonGPT tree under `/data/synthongpt_data/`
- everything chowned to `2112:0`

The kind PV's `hostPath` is `/data` — same path the production VMs use for the
host-side data directory. On kind that path resolves *inside* the
`kind-control-plane` Docker container, not on your laptop, so you stage data
with `docker cp ... kind-control-plane:/data/…` (see `pvc-data-runbook.md`).

You can defer database / SynthonGPT data until just before installing, but the
directories must exist by the time the corresponding pods schedule, or they
will crashloop.

## 4. Images

Default path — `image.source: acr` for every component. Nothing to build:
once the image-pull-secret from §2 is applied, kubelet pulls
`cheese.azurecr.io/on-prem/<svc>/cheese-customer:latest` at install time.
Skip the rest of this section.

Alternative — rebuild from source. Flip `image.source: local` in
`values-onprem.yaml` for the components you want to iterate on, then:

```bash
# Only search-ui needs a build-env file — its Vite bundle bakes in the
# Supabase URL/key and feature flags at build time. The three Python
# backends have nothing tenant-specific to bake in; their docker build
# paths are hardcoded in scripts/build-source-images.sh.
cp env/cheese-search-ui.build.env.example env/cheese-search-ui.build.env
$EDITOR env/cheese-search-ui.build.env       # fill in SUPABASE_URL / SUPABASE_ANON_KEY

# Build + load all four local:dev images:
make build-source-images
make load-images
```

`make build-source-images` calls `docker manifest inspect` against the ACR
base image before building orchestrator/database, since their
`Dockerfile-on-prem` does `FROM cheese.azurecr.io/...:base`. If you haven't
run `docker login cheese.azurecr.io` it bails early with a clear error
rather than failing mid-build. synthongpt and search-ui base on public
images (`python:3.11-slim`, `node:23-alpine`), so they build with no ACR
auth — the preflight only runs when orchestrator or database is in the
`BUILD` set.

Subset a single component when iterating:

```bash
BUILD="cheese-orchestrator" make build-source-images
LOAD="cheese-orchestrator-local" make load-images
```

The kubelet on kind cannot reach your local docker daemon — every image
consumed by `image.source: local` has to be sideloaded. Re-run the build +
load for the affected service after every code change.

## 5. Helm install

```bash
# 5.1 — fill in site values (non-secret + secret), copying the .example siblings:
cp charts/cheese/values-onprem.yaml.example  charts/cheese/values-onprem.yaml
cp charts/cheese/values-secrets.yaml.example charts/cheese/values-secrets.yaml
$EDITOR charts/cheese/values-{onprem,secrets}.yaml

# 5.2 — install:
helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml

# 5.3 — wait for rollouts. Data-plane workers (jobs-exec, download-exec) and
# SynthonGPT (checkpoint load) take the longest:
kubectl -n cheese rollout status deploy/cheese-database-app
kubectl -n cheese rollout status deploy/cheese-database-jobs-db
kubectl -n cheese rollout status deploy/cheese-synthongpt --timeout=10m
kubectl -n cheese rollout status deploy/cheese-orchestrator
kubectl -n cheese rollout status deploy/cheese-search-ui
```

Resource names are hardcoded in the chart (`cheese-database-app`,
`cheese-orchestrator`, …) so the orchestrator's default in-cluster service
URLs work out of the box.

To skip a component, set `<component>.enabled: false` in `values-onprem.yaml`.
Common case: `synthongpt: { enabled: false }` if SynthonGPT is not part of the
install — only `/search` and `/database_info` calls that hit SynthonGPT are
affected.

### Headless variant (API-only, no UI / no auth / no Supabase)

Layer `values-headless.yaml.example` on top of the regular values to drop the
search-ui frontend, disable user auth, and disable the Supabase integration:

```bash
helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml \
  -f charts/cheese/values-headless.yaml.example
```

The orchestrator stays reachable at `http://cheese-api.localtest.me`. See
[`headless-variant.md`](./headless-variant.md) for the full diff, verification
steps, and the "no ingress at all" option.

## 6. Verification

```bash
# All deployments Ready:
kubectl -n cheese get deploy

# Orchestrator can reach the data plane:
kubectl -n cheese exec deploy/cheese-orchestrator -- \
  curl -sf http://cheese-database-app:8001/health
kubectl -n cheese exec deploy/cheese-orchestrator -- \
  curl -sf http://cheese-database-jobs-db:8001/health
kubectl -n cheese exec deploy/cheese-orchestrator -- \
  curl -sf http://cheese-synthongpt:8000/health        # only if installed

# UI reachable from the host:
curl -sI http://cheese-ui.localtest.me
curl -sI http://cheese-api.localtest.me
```

Open `http://cheese-ui.localtest.me` in a browser to drive the full stack.

## 7. Reinstall after a code change

Rebuild + reload the affected image, then bounce the deployment directly —
`helm upgrade` is only needed for value changes.

```bash
BUILD="cheese-orchestrator" make build-source-images
LOAD="cheese-orchestrator-local" make load-images
kubectl -n cheese rollout restart deploy/cheese-orchestrator
```

For values-only changes:

```bash
helm upgrade cheese charts/cheese \
  -n cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml
```

## 8. Teardown

```bash
helm uninstall cheese -n cheese
```

Wipe data only if you really mean it:

```bash
kubectl -n cheese delete pvc cheese-data-pvc
kubectl delete pv cheese-data-pv
docker exec kind-control-plane rm -rf /data            # destroys all on-disk data (kind only)
# On a real on-prem node (no kind layer), wipe /data on the host directly.
```

Drop the cluster:

```bash
kind delete cluster --name kind
```
