# cheese-k8s

A single Helm chart (`charts/cheese`) that brings up the whole on-prem CHEESE
stack from one `helm install`. Every component is toggled with a top-level
`.enabled` key in **one** `values.yaml` — there are no per-environment overlay
files. The environment (storage class + ingress class) is selected with
`deployment.target`.

## Components

| Component | Key | Default | Notes |
|---|---|---|---|
| Database (app / jobs-db / jobs-exec / download-exec / **file-server**) | `database.enabled` | on | search engine + result file server, all off one image |
| Orchestrator | `orchestrator.enabled` | on | the API the UI calls |
| Search UI | `searchUi.enabled` | on | public frontend |
| SynthonGPT | `synthongpt.enabled` | on | synthon model server |
| **Ketcher** | `ketcher.enabled` | on | self-hosted molecule editor (UI iframes it) |
| **Inference** | `inference.enabled` | off | electrostatics; UI degrades gracefully if absent |
| **Alignment** | `alignment.enabled` | off | conformer alignment, license-gated |
| **Supabase** | `supabase.enabled` | off | in-cluster auth + per-user spaces (test profile) |
| **oauth2-proxy** | `oauth2Proxy.enabled` | off | SSO stub (alternate to Supabase) |

## Deployment target

`deployment.target` selects storage + ingress class (see `templates/_platform.tpl`):

- **`local`** — kind / bare-metal dev. hostPath PV (`cheese-local-manual`) + `nginx`. Fully supported and tested.
- **`aws`** — **scaffold only** (no AWS sources/images yet): `gp3`/`efs-sc` + `alb` stubs, untested.
- **`azure`** — **deprecated / unsupported.**

An explicit `deployment.storage.className` / `deployment.ingress.className` always wins.

## Secrets

Each secret-producing component (`database`, `orchestrator`, `searchUi`, `supabase`)
accepts `secret.existingSecret: <name>`:

- **Set it** → reference your own pre-created Secret (Vault / External Secrets
  Operator / SealedSecrets / `kubectl create secret`). The chart renders no inline
  Secret. Required keys per component are listed in `values-secrets.yaml.example`.
- **Leave it empty** → the chart renders the Secret inline from your values
  (self-contained / local path). See `values-secrets.yaml.example`.

## Quick start — local (kind)

Prerequisites: Docker, `kind` ≥ 0.20, `kubectl` ≥ 1.28, `helm` ≥ 3.14.

```bash
# 1. Cluster + ingress controller
kind create cluster --config kind/cluster.yaml
make install-ingress-controller

# 2. Stage data on /data (license file, per-database dirs, SynthonGPT tree),
#    all chowned 2112:0. The chart creates the PV + PVC for you — no manual
#    kubectl apply. Layout + kind staging commands: docs/pvc-data-runbook.md.

# 3. Images.
#    Default (image.source: acr) — apply the ACR pull secret; kubelet pulls
#    cheese.azurecr.io/on-prem/<svc>/cheese-customer:latest at install:
cp manifests/base/image-pull-secret.example.yaml manifests/base/image-pull-secret.yaml
$EDITOR manifests/base/image-pull-secret.yaml      # fill in real ACR creds
kubectl create namespace cheese
kubectl apply -f manifests/base/image-pull-secret.yaml
#    Alternative — image.source: local for components you rebuild from source:
#      make build-source-images && make load-images

# 4. Fill in secrets and install with the local profile
cp charts/cheese/values-secrets.yaml.example charts/cheese/values-secrets.yaml
$EDITOR charts/cheese/values-secrets.yaml
helm install cheese charts/cheese -n cheese --create-namespace \
  -f charts/cheese/values-secrets.yaml \
  -f local-profile.yaml          # see "Profiles" below (or use --set flags)

# 5. Wait for rollouts (SynthonGPT loads checkpoints — give it ~10m)
kubectl -n cheese get pods
```

UI → `http://cheese-ui.localtest.me`, orchestrator → `http://cheese-api.localtest.me`.

## Profiles

The single `values.yaml` defaults are production-leaning (target=local but supabase
off, etc.). Layer a tiny profile file (or `--set` flags) for each environment.

**local / test** (`local-profile.yaml`) — in-cluster Supabase auth, local storage:

```yaml
deployment:
  target: local
supabase:
  enabled: true
  allowedEmailDomains: [deepmedchem.com]
orchestrator:
  supabase:
    enable: "true"
  env:
    enable_auth: "true"
ketcher:
  enabled: true
  ingress:                          # ketcher origin must be browser-reachable
    enabled: true
    hosts: [{ host: cheese-ketcher.localtest.me }]
```

**prod (aws scaffold)** (`prod-profile.yaml`) — external secrets, no in-cluster Supabase:

```yaml
deployment:
  target: aws                       # scaffold; storageClass/ingress are stubs until AWS images exist
  storage:
    accessMode: ReadWriteMany       # efs-sc — required to scale the search role across nodes
database:   { secret: { existingSecret: cheese-database } }
orchestrator: { secret: { existingSecret: cheese-orchestrator } }
searchUi:   { secret: { existingSecret: cheese-search-ui-secret } }
supabase:   { enabled: false }
inference:  { enabled: true }
alignment:  { enabled: true }
searchUi:
  config:
    FRONTEND_URL: https://cheese.example.com
    KETCHER_ORIGIN: https://ketcher.example.com
    SUPABASE_PUBLIC_URL: https://supabase.example.com
```

## Headless (API-only)

Set `searchUi.enabled: false` and turn auth off:

```yaml
searchUi:     { enabled: false }
ketcher:      { enabled: false }
orchestrator:
  supabase: { enable: "false" }
  env:      { enable_auth: "false" }
```

You get `cheese-database` + `cheese-synthongpt` + `cheese-orchestrator` behind the
`cheese-api.localtest.me` ingress, no UI/auth. Sanity-check:
`curl -sf http://cheese-api.localtest.me/health`.

## Generate license

The license is keyed to the host hardware running the database container — on kind
that's the `kind-control-plane` container, so keygen runs as a pod:

```bash
kubectl run -n cheese cheese-license-keygen --rm -it --restart=Never \
  --image=cheese-database-local:dev --image-pull-policy=IfNotPresent \
  --command -- python -c 'from generate_license_ID import main; main()'
```

Send the key to support, then drop the returned JSON onto `/data`:

```bash
docker cp cheese_license_file.json kind-control-plane:/data/cheese_license_file.json
docker exec kind-control-plane chown 2112:0 /data/cheese_license_file.json
```

Set `database.secret.cheeseLicenseFile` and `orchestrator.secret.cheeseLicenseFile`
to that filename (they must match — one shared PVC). On a real node, drop the
`docker exec`/`docker cp` prefixes.

## Verify the chart (no cluster)

```bash
helm lint charts/cheese
helm template cheese charts/cheese                                   # defaults
helm template cheese charts/cheese --set supabase.enabled=true \
  --set supabase.secret.postgresPassword=x --set supabase.secret.jwtSecret=x \
  --set supabase.secret.anonKey=x --set supabase.secret.serviceRoleKey=x
helm template cheese charts/cheese --set deployment.target=aws       # storage gp3 / ingress alb, no local PV
helm template cheese charts/cheese --set orchestrator.secret.existingSecret=my-sec
```

## Repo layout

```
cheese-k8s/
├── charts/cheese/
│   ├── Chart.yaml
│   ├── values.yaml                 # the one source of truth (all components + deployment.target)
│   ├── values-secrets.yaml.example # inline secrets / existingSecret contract
│   ├── files/supabase/             # vendored gateway.conf + SQL (db / schema / on-prem overlay)
│   └── templates/
│       ├── _helpers.tpl  _platform.tpl
│       ├── data-pvc.yaml  data-pv-local.yaml
│       ├── database-* orchestrator-* synthongpt-* search-ui-*
│       ├── ketcher-* inference-* alignment-*
│       └── supabase/   # db / auth / rest / meta / studio / gateway / sql-configmap / init-job
├── docs/                           # install-order, pvc-data-runbook, architecture, kind-bringup-log
├── env/cheese-search-ui.build.env.example   # Vite build args baked into the UI bundle
├── kind/cluster.yaml
├── manifests/base/                 # namespace.yaml, image-pull-secret.example.yaml
└── scripts/  Makefile              # build-source-images, load-images, install-ingress-controller
```

## Conventions

- **Image source.** Each app component accepts `image.source: local | acr`.
- **Shared PVC at `/data`.** database / orchestrator / synthongpt / alignment mount
  `cheese-data-pvc` (RWO by default; set `deployment.storage.accessMode: ReadWriteMany`
  on a cloud target to scale the search role across nodes). Supabase uses its own PVC.
- **UID 2112 group 0.** Pods touching `/data` run as that identity; stage files `chown -R 2112:0`.
- **Stable resource names.** `cheese-database-app`, `cheese-orchestrator`, `cheese-inference`,
  `cheese-alignment-app`, `cheese-ketcher`, `supabase-*` — so in-cluster service URLs work out of the box.

## Teardown

```bash
helm uninstall cheese -n cheese
kubectl -n cheese delete pvc -l app.kubernetes.io/name=cheese
kubectl delete pv cheese-data-pv
docker exec kind-control-plane rm -rf /data    # destroys on-disk data (kind only)
kind delete cluster
```
