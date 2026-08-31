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
| `values-kind-smoke.yaml.example` | ready-made smoke profile: database + orchestrator + one 655 MB database + the call-home licence agent |
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
default `image.source: ecr` and skip this — kubelet pulls the released images
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

> `cheese-orchestrator` and `cheese-database` are **mandatory** — the chart
> enables both by default and nothing works without them, so both scripts add
> them back if a `BUILD`/`LOAD` override leaves one out, and say so on stderr.
> The two commands above therefore also build/load `cheese-database`. Pass the
> pair explicitly when you mean only the core stack.

The upstream repos (`cheese-orchestrator`, `cheese-database`, `cheese-search-ui`,
`synthongpt-prod`) are expected as **siblings of the `cheese-on-prem` checkout**;
override with `SOURCES_ROOT=/path/to/repos` if they live elsewhere. Then flip
`image.source: local` in your values for the components you rebuilt.

## Licence on kind

Use **call-home** licensing — the licence agent. On kind it is not merely supported, it is
*simpler* than the alternative: the fingerprint is the cluster's own `kube-system`
namespace UID, which is a perfectly valid fingerprint, so there is nothing
machine-specific to work around.

```bash
kubectl -n cheese create secret generic dmch-license-key \
  --from-literal=licenseKey='DMCH-…'
```

```yaml
licensingAgent:
  enabled: true
  image:
    source: ecr                 # tag is pinned by the chart, not onprem.imageTag
  secret:
    existingSecret: dmch-license-key
```

The agent writes the licence file onto the PVC at exactly the path
`database.secret.cheeseLicenseFile` names, and renews it daily. Watch it with
`kubectl -n cheese logs -f deploy/dmch-licensing-agent`.

`values-kind-smoke.yaml.example` in this directory is a ready-made profile that
does this — database + orchestrator + one small database + the agent.

> ### ⚠️ Recreating the cluster costs an activation slot
>
> `kind delete cluster` + `kind create` mints a **new** `kube-system` UID, so a
> new fingerprint, so another activation. `max_activations` defaults to 1 and the
> next one is refused with `409 max_activations_reached` — and a dead activation
> only ages out after 45 days. kind's hostPath PV lives *inside* the node
> container, so deleting the cluster also destroys the licence file and the
> agent's state; the fresh cluster activates from scratch.
>
> Budget for it: get the stale activation released, or ask for a test key with
> more slots. Do not pin a fingerprint by hand to dodge the limit — one
> fingerprint is one installation, and that is the whole basis of the scheme.

### Why not the air-gapped file here

The air-gapped licence works fine on a cluster if you pin one identity across its
nodes — that is the production path for a cluster with no egress (chart
`README.md`). It is just miserable in a dev loop: on kind the fingerprint comes
from the `kind-control-plane` container, which reports `product_name` as `kind`,
so a licence cut for the real host is rejected and restoring the host value needs
an ephemeral `mount --bind` inside the node after **every** cluster re-create.
The agent removes all of that.

## Teardown

```bash
helm uninstall cheese -n cheese
docker exec kind-control-plane rm -rf /data   # destroys the node-local data
kind delete cluster
```
