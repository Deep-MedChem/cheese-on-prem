# cheese-k8s

A single Helm chart (`charts/cheese`) that brings up the four components of the
on-prem CHEESE stack:

- `cheese-database` — search engine, four roles off one image
- `cheese-orchestrator` — API the UI calls, fan-out to the data plane
- `cheese-synthongpt` — synthon model server (optional)
- `cheese-search-ui` — public-facing frontend

Components are toggled with `database.enabled` / `synthongpt.enabled` /
`orchestrator.enabled` / `searchUi.enabled` in values. A `values-headless.yaml`
overlay is provided for the "API-only" variant (no UI, no auth, no Supabase) —
see [Headless variant](#headless-variant) below.

Target environments are kind (developer laptop) and a single bare-metal
on-prem node. Multi-node / cloud deployments are out of scope.

## Where to look

- [`docs/install-order.md`](docs/install-order.md) — canonical playbook,
  step-by-step. **Start here.**
- [`docs/pvc-data-runbook.md`](docs/pvc-data-runbook.md) — what files the
  chart expects on the shared PVC at `/data` and how to stage them.
- [`docs/architecture.md`](docs/architecture.md) — diagrams and notes on
  how the four components wire together.
- [`docs/kind-bringup-log.md`](docs/kind-bringup-log.md) — the as-actually-run
  log of a fresh kind bringup, with gotchas.
- [`docs/headless-variant.md`](docs/headless-variant.md) — API-only install
  (no UI, no auth, no Supabase).

## Quick start (kind)

Prerequisites: Docker, `kind` ≥ 0.20, `kubectl` ≥ 1.28, `helm` ≥ 3.14, and
the four upstream repos (`cheese-orchestrator`, `cheese-database`,
`cheese-search-ui`, `synthongpt-prod`) cloned alongside this one.

```bash
# 1. Cluster + ingress
kind create cluster --config kind/cluster.yaml
make install-ingress-controller

# 2. Namespace + PV + PVC
kubectl apply -f manifests/base/namespace.yaml
kubectl apply -f manifests/base/persistent-volume.local-example.yaml
kubectl apply -f manifests/base/persistent-volume-claim.yaml
kubectl -n cheese get pvc cheese-data-pvc           # STATUS: Bound

# 3. Stage data on the PVC — license file, per-database dirs, SynthonGPT
#    tree, all chowned to 2112:0. License generation: see "Generate license"
#    below. Layout + commands: docs/pvc-data-runbook.md (also creates /data
#    on the kind node). Pods crashloop if their directories are missing.

# 4. Images.
#    Default (image.source: acr) — apply the image-pull-secret, then kubelet
#    pulls cheese.azurecr.io/on-prem/<svc>/cheese-customer:latest at install
#    time. Nothing to build locally:
cp manifests/base/image-pull-secret.example.yaml manifests/base/image-pull-secret.yaml
$EDITOR manifests/base/image-pull-secret.yaml      # fill in real ACR creds
kubectl apply -f manifests/base/image-pull-secret.yaml
#
#    Alternative — set image.source: local in values-onprem.yaml for the
#    components you want to rebuild from source, then:
#      cp env/cheese-search-ui.build.env.example env/cheese-search-ui.build.env  # only if rebuilding the UI
#      make build-source-images        # orchestrator/database FROM cheese.azurecr.io:base — needs `docker login cheese.azurecr.io`
#      make load-images                # sideload into the kind cluster
#    Subset: BUILD="cheese-search-ui" make build-source-images
#            LOAD="cheese-search-ui-local" make load-images

# 5. Fill in values
cp charts/cheese/values-onprem.yaml.example  charts/cheese/values-onprem.yaml
cp charts/cheese/values-secrets.yaml.example charts/cheese/values-secrets.yaml
$EDITOR charts/cheese/values-{onprem,secrets}.yaml

# 6. Install — single chart, no `helm dependency build` step
helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml

# 7. Wait for rollouts. SynthonGPT loads checkpoints — give it ~10m:
kubectl -n cheese rollout status deploy/cheese-database-app
kubectl -n cheese rollout status deploy/cheese-orchestrator
kubectl -n cheese rollout status deploy/cheese-synthongpt --timeout=10m   # if enabled
kubectl -n cheese rollout status deploy/cheese-search-ui                  # full stack only
```

The UI is then reachable at `http://cheese-ui.localtest.me` and the
orchestrator at `http://cheese-api.localtest.me`. For the API-only install
(no UI / auth / Supabase), layer `values-headless.yaml.example` — see
[Headless variant](#headless-variant) below.

## Generate license

The CHEESE license is keyed to the host hardware that runs the database
container. On kind, that is the `kind-control-plane` Docker container — not
your laptop — so the keygen has to run as a pod on the cluster:

```bash
kubectl run -n cheese cheese-license-keygen \
  --rm -it --restart=Never \
  --image=cheese-database-local:dev \
  --image-pull-policy=IfNotPresent \
  --overrides='{"spec":{"containers":[{"name":"cheese-license-keygen","image":"cheese-database-local:dev","imagePullPolicy":"IfNotPresent","workingDir":"/opt/cheese/cheese_database","command":["python","-c","from generate_license_ID import main; print(\"Your license key is\"); main()"],"stdin":true,"tty":true}]}}'
```

Send the printed key to support; they return a JSON license file. Drop it
into the kind node, where the PVC's hostPath resolves:

```bash
docker cp cheese_license_file.json kind-control-plane:/data/cheese_license_file.json
docker exec kind-control-plane chown 2112:0 /data/cheese_license_file.json
```

Set `secret.cheeseLicenseFile` to that filename in **both** the `database`
and `orchestrator` value blocks (the orchestrator reads the same file at
boot). The two values must match, since they refer to the one shared PVC.

> On a real on-prem node (no kind layer), drop the `docker exec` /
> `docker cp` prefixes — `/data` on the host *is* the path the pods see.

## Headless variant

Set `searchUi.enabled: false` plus the auth/Supabase toggles and you get an
API-only install: `cheese-database` + `cheese-synthongpt` + `cheese-orchestrator`
behind the `cheese-api.localtest.me` ingress, with no UI, no Supabase, and no
user-auth check in front of the API. Stripe is not part of this chart, so there
is nothing to disable for it.

The overlay lives at `charts/cheese/values-headless.yaml.example`. Layer it on
top of the regular values files at install time:

```bash
cp charts/cheese/values-headless.yaml.example \
   charts/cheese/values-headless.yaml          # optional — overlay is already valid as-is

helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml \
  -f charts/cheese/values-headless.yaml.example
```

What you get (vs the full stack):

| Resource                            | Full | Headless |
|-------------------------------------|------|----------|
| `cheese-database-*` (4 roles)       | yes  | yes      |
| `cheese-synthongpt`                 | yes  | yes      |
| `cheese-orchestrator`               | yes  | yes      |
| `cheese-search-ui` (deploy/svc/ing) | yes  | no       |
| Ingress `cheese-api.localtest.me`   | yes  | yes      |
| Ingress `cheese-ui.localtest.me`    | yes  | no       |
| Orchestrator `ENABLE_AUTH`          | per values | `false` |
| Orchestrator `ENABLE_SUPABASE`      | per values | `false` |

Sanity-check the API after install:

```bash
curl -sf http://cheese-api.localtest.me/health        # → "OK"
```

If you don't want any ingress at all, also disable `orchestrator.ingress.public`
in your overlay and reach the API with
`kubectl port-forward -n cheese svc/cheese-orchestrator 8001:80`.

## Repo layout

```
cheese-k8s/
├── charts/
│   └── cheese/                  # single chart — installs the whole stack
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-onprem.yaml.example
│       ├── values-secrets.yaml.example
│       ├── values-headless.yaml.example  # API-only overlay (no UI / auth / Supabase)
│       └── templates/
│           ├── _helpers.tpl
│           ├── database-{configmap,secret,deployments,services}.yaml
│           ├── orchestrator-{deployment,service,secret,ingress,hpa,pdb}.yaml
│           ├── synthongpt-{deployment,service,hpa,pdb}.yaml
│           └── search-ui-{configmap,secret,deployment,service,ingress}.yaml
├── docs/
│   ├── install-order.md         # canonical playbook
│   ├── pvc-data-runbook.md      # what to put on /data
│   ├── architecture.md
│   └── kind-bringup-log.md      # log of a working kind bringup
├── env/
│   └── cheese-search-ui.build.env.example  # Vite build args baked into the UI bundle
├── kind/
│   └── cluster.yaml             # kind cluster config (ports 80/443 → host)
├── manifests/base/
│   ├── namespace.yaml
│   ├── persistent-volume.local-example.yaml
│   ├── persistent-volume-claim.yaml
│   └── image-pull-secret.example.yaml
├── scripts/
│   ├── build-source-images.sh   # build all four local:dev images (BUILD=… for a subset)
│   └── load-kind-images.sh      # sideload them into the kind cluster
└── Makefile                     # shortcuts: build-source-images, load-images, install-ingress-controller
```

## Conventions

- **Image source switch.** Every component accepts `image.source: local | acr`.
  `local` consumes `<component>-local:dev` (built locally and `kind load`-ed).
  `acr` pulls from `cheese.azurecr.io/...` and needs the
  `image-pull-secret.yaml` from `manifests/base/`.
- **Shared PVC at `/data`.** Database, orchestrator, and synthongpt all mount
  the single `cheese-data-pvc` at `/data` (top-level `data:` block in values).
  Search UI is stateless and doesn't mount it. The PV's `hostPath` is `/data`
  on the node; on kind, that is inside the kind-control-plane container.
- **UID 2112 group 0.** All chart pods run as that identity. Files staged
  on the PVC must be readable by it (`chown -R 2112:0 ...`).
- **Stable resource names.** Names are hardcoded in the chart
  (`cheese-database-app`, `cheese-orchestrator`, `cheese-synthongpt`,
  `cheese-search-ui`, …) so the orchestrator's default in-cluster service
  URLs work without per-release tweaks.

## Teardown

```bash
helm uninstall cheese -n cheese
kubectl -n cheese delete pvc cheese-data-pvc
kubectl delete pv cheese-data-pv
docker exec kind-control-plane rm -rf /data    # destroys all on-disk data (kind only)
kind delete cluster --name kind
```
