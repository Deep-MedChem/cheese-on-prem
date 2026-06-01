# Headless variant — API-only install

"Headless" here means the on-prem stack with the **search UI**, **user
authorization**, and **Supabase** all removed, leaving just the orchestrator
API in front of the database and SynthonGPT.

There is no Stripe code anywhere in this stack (chart or upstream
`cheese-orchestrator`), so "no Stripe" needs no toggle.

## What's removed vs the full install

| Resource / behavior                       | Full | Headless |
|-------------------------------------------|------|----------|
| `cheese-database-*` (4 roles)             | yes  | yes      |
| `cheese-synthongpt`                       | yes  | yes      |
| `cheese-orchestrator`                     | yes  | yes      |
| `cheese-search-ui` Deployment + Service   | yes  | **no**   |
| `cheese-search-ui` ConfigMap + Secret     | yes  | **no**   |
| Ingress `cheese-ui.localtest.me`          | yes  | **no**   |
| Ingress `cheese-api.localtest.me`         | yes  | yes      |
| Orchestrator `ENABLE_AUTH`                | per values | **false** |
| Orchestrator `ENABLE_SUPABASE`            | per values | **false** |
| Orchestrator `SUPABASE_URL`               | per values | **empty** |

The toggles are all that the orchestrator code checks:

- `cheese_orchestrator/cheese_core.py` reads `ENABLE_AUTH`, `ENABLE_TRACKING`,
  `ENABLE_RATE_LIMITS`, `ENABLE_NOTIFICATIONS` from env.
- `cheese_orchestrator/auth.py` reads `ENABLE_SUPABASE` and `SUPABASE_URL`.
- `cheese_orchestrator/app.py` only imports `auth_supabase` when
  `ENABLE_AUTH or ENABLE_TRACKING` is true, so the Supabase SDK is never
  loaded in headless mode.

## How it's packaged

A single overlay file:

```
charts/cheese/values-headless.yaml.example
```

…which sets exactly the four toggles above plus `searchUi.enabled: false`.
Everything else falls back to `values.yaml` / `values-onprem.yaml`. The chart
templates themselves are unchanged — every search-ui template already gates
on `.Values.searchUi.enabled`, so they render to nothing.

## Install

```bash
# One-time: copy the example overlay (optional — overlay works as-is too).
cp charts/cheese/values-headless.yaml.example \
   charts/cheese/values-headless.yaml

helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml \
  -f charts/cheese/values-headless.yaml.example
```

To switch a running full install into headless:

```bash
helm uninstall cheese -n cheese
# Selectors differ between UI and headless installs — uninstall, don't upgrade.

helm install cheese charts/cheese -n cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml \
  -f charts/cheese/values-headless.yaml.example
```

The PVC and on-disk `/data` survive the uninstall.

## Verify

```bash
# 1. Resource list — no cheese-search-ui anywhere:
kubectl -n cheese get deploy,svc,ingress

# Expected (data-plane pods may be Running or CrashLoopBackOff depending on
# whether you've staged the license + models on the PVC; that is independent
# of the headless variant):
#   deploy/cheese-database-app, jobs-db, jobs-exec, download-exec
#   deploy/cheese-orchestrator
#   deploy/cheese-synthongpt
#   svc/cheese-database-app, jobs-db, orchestrator, synthongpt
#   ingress/cheese-orchestrator-public  (cheese-api.localtest.me)

# 2. Orchestrator env confirms auth / Supabase off:
kubectl -n cheese exec deploy/cheese-orchestrator -- sh -c \
  'echo ENABLE_AUTH=$ENABLE_AUTH; echo ENABLE_SUPABASE=$ENABLE_SUPABASE; echo SUPABASE_URL=$SUPABASE_URL'
# →
#   ENABLE_AUTH=false
#   ENABLE_SUPABASE=false
#   SUPABASE_URL=

# 3. /health responds 200 unauthenticated:
curl -sf http://cheese-api.localtest.me/health
# → "OK"

# 4. /docs is reachable (FastAPI auto docs):
curl -sI http://cheese-api.localtest.me/docs | head -1
# → HTTP/1.1 200 OK

# 5. /openapi.json lists the full API surface:
curl -sf http://cheese-api.localtest.me/openapi.json | \
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)["paths"]), "paths")'
# → 37 paths
```

Endpoints that hit `cheese-database-app` (e.g. `/available_databases`,
`/random_molecule`, `/molsearch`) will return 500 until the data plane is up.
That depends on a real `PRODUCTION` secret + decrypted models on `/data`, not
on the headless variant. See [`pvc-data-runbook.md`](./pvc-data-runbook.md).

## No ingress at all (in-cluster only)

If you don't want any ingress, set the API ingress off in your overlay:

```yaml
orchestrator:
  ingress:
    public:
      enabled: false
    private:
      enabled: false
```

Reach the orchestrator via port-forward:

```bash
kubectl port-forward -n cheese svc/cheese-orchestrator 8001:80
curl -sf http://localhost:8001/health
```

## Teardown

Same as the full stack:

```bash
helm uninstall cheese -n cheese
```
