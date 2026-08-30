# The licence agent on Kubernetes <kbd>☸️ k8s</kbd> <kbd>🌐 v1 licensing</kbd>

The chart can run a small **licence agent** next to the stack. It exchanges the
`DMCH-…` licence key you were issued for a signed licence file, writes that file
onto the shared `/data` PVC at exactly the path the product containers read, and
renews it daily — so nobody has to hand-install or refresh a licence file.

It is **optional and off by default** (`licenseAgent.enabled: false`). With it
off, the chart behaves exactly as before: you place a licence file on the PVC
yourself.

> ### ⚠️ Read this before you rely on it
>
> **No released CHEESE image verifies a v1 licence yet.** The verifier is still
> open work in the four gated repos (`cheese-database` #155,
> `cheese-orchestrator` #179, `cheese-inference` #7, `conformer-alignment-api`
> #10). This chart plumbing deliberately lands **ahead of enforcement**.
>
> Concretely, today:
>
> - A v1 licence file handed to a **current** image is rejected by that image's
>   v0 verifier as **"signature does not match license content"**. The message is
>   misleading — the signature is fine, the image simply predates the scheme.
> - So do **not** point `database.secret.cheeseLicenseFile` at the agent's output
>   on a stack you need to keep running, unless you are running images built from
>   the verifier branches.
> - Enabling the agent is safe and useful now for *plumbing* work: activating an
>   installation, proving connectivity, checking the fingerprint the server sees.
>
> Talk to DeepMedChem before wiring this into a customer or partner cluster.

## v0 vs v1 — which one you have

Two licensing schemes exist. **On Kubernetes only v1 can work**: v0 binds a
licence to one machine's hardware id, which is meaningless on a cluster whose
nodes come and go.

| | ✈️ **v0 — "air-gapped"** | 🌐 **v1 — "call home"** (this agent) |
|---|---|---|
| You were given | a signed licence **file** | a licence **key**, a `DMCH-…` string |
| Obtained by | emailing us a machine fingerprint | the agent, automatically |
| Bound to | **one physical machine's** DMI hardware id | **the whole installation** (here: the cluster) |
| Valid for | the contract term | **30 days**, renewed daily |
| Needs network | never | a daily outbound HTTPS check-in |
| Access can be withdrawn | no | yes — stop renewing |
| Supported on | Docker Compose / single host | Kubernetes, Docker Compose |

Some older internal notes call the agent "v2". That numbering is wrong: **v0 is
the offline file, v1 is the agent.**

⚠️ A **`DMCH-PTN-…` token is not a licence key.** It is a *partner* token, used to
issue keys for end-customers via `POST /partner/v1/licenses`. Putting one in the
licence secret fails with `401 partner_token_not_a_license_key`; the chart
refuses to render if it spots one.

## One licence per installation — and what "installation" means here

The agent identifies this installation to the licensing server with a
**fingerprint**, and in a pod that fingerprint is the **UID of the `kube-system`
namespace**. That UID is created with the cluster and never changes, so:

- Nodes can be added, replaced, drained or rebooted with nothing to do.
- The licence covers however many machines the cluster spans.
- **Every Helm release in the same cluster produces the same fingerprint.**

That last point decides how to licence a multi-tenant deployment:

| You are | Licences needed | Why |
|---|---|---|
| Running CHEESE for **your own** organisation | **one** | One cluster, one installation. |
| Running **N releases** (namespaces) in **one** cluster for several internal teams | **one** | They share the cluster's fingerprint. N licences would each try to activate the *same* fingerprint — you would be paying for slots you cannot use, and the second key gets the first key's fingerprint. Separate the tenants at the **application** layer (per-user spaces / Supabase auth), not with per-tenant licences. |
| A **partner** deploying CHEESE at your own end-customers, each in **their own** cluster | **one per end-customer cluster** | Different clusters, different fingerprints. Issue those keys yourself with your `DMCH-PTN-…` partner token. |

`max_activations` on the licence (default **1**) is how many live installations a
single key may have at once. When the slots are full the next activation is
refused with `409 max_activations_reached`, and the response lists the live
activations so a dead one can be identified and released.

## Enable it

You need: the licensing server URL, your `DMCH-…` key, and outbound HTTPS from
the cluster.

### With your own secret store <kbd>recommended</kbd>

```bash
kubectl -n cheese create secret generic cheese-license-key \
  --from-literal=licenseKey='DMCH-…'
```

```yaml
licenseAgent:
  enabled: true
  serverUrl: https://licensing.deepmedchem.com
  secret:
    existingSecret: cheese-license-key      # any Secret with a `licenseKey` key
```

`existingSecret` is the same convention the other components use, so Vault,
External Secrets Operator, SealedSecrets or a plain pre-created Secret all work.
The chart then renders **no** Secret of its own.

### Self-contained (inline)

```yaml
licenseAgent:
  enabled: true
  secret:
    licenseKey: "DMCH-…"        # rendered into Secret `cheese-license-key`
```

Keep that in your gitignored secrets values file (see
[`../charts/cheese/values-secrets.yaml.example`](../charts/cheese/values-secrets.yaml.example)).

### What gets created

| Object | Namespace | Purpose |
|---|---|---|
| `Deployment/cheese-license-agent` | release ns | 1 replica, `Recreate` — single writer of the licence file |
| `ServiceAccount/cheese-license-agent` | release ns | identity used to read the fingerprint |
| `Secret/cheese-license-key` | release ns | only when `secret.existingSecret` is empty |
| `Role` + `RoleBinding` `<release>-license-agent-fingerprint` | **`kube-system`** | the single API permission (see below) |

No Service and no ingress: the agent takes no inbound traffic.

## The one permission it needs

The agent reads the `kube-system` Namespace **object** — nothing else — because
its UID is the fingerprint. That is granted by a `Role` in `kube-system`,
restricted to that one object:

```yaml
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    resourceNames: ["kube-system"]
    verbs: ["get"]
```

A namespaced RoleBinding *does* authorise this: the API server records
`namespace=kube-system` for `GET /api/v1/namespaces/kube-system`, so RBAC
resolves it as a namespaced request. Probed on Kubernetes v1.35 with a token for
that ServiceAccount:

| Request | Result |
|---|---|
| `get` namespace `kube-system` | **200** |
| `list` namespaces | 403 |
| `get` namespace `default` | 403 |
| `list` secrets in `kube-system` | 403 |
| `list` pods in `kube-system` | 403 |
| same request with the binding removed | 403 |

If your cluster policy forbids creating objects inside `kube-system`, switch to
an equally narrow cluster-scoped grant:

```yaml
licenseAgent:
  rbac:
    scope: cluster        # ClusterRole + ClusterRoleBinding, resourceNames: [kube-system]
```

`resourceNames` do not apply to `list`/`watch`, so that variant does not grant
listing either. To wire RBAC entirely yourself:

```yaml
licenseAgent:
  rbac: { create: false }
  serviceAccount: { create: false, name: my-own-sa }
```

## Why the agent is not root, and what runs as root instead

The licence file has to land on the shared `/data` PVC, whose **root directory is
owned by `root`** (see [pvc-data-runbook.md](pvc-data-runbook.md)). Creating and
atomically replacing a file there is a *directory* write, so an agent running as
UID 2112 cannot do it. The earlier hand-rolled manifests solved that by running
the agent as `runAsUser: 0`. That is not an acceptable default for a shipped
chart.

What this chart does instead: a short **initContainer runs as root once per pod
start** and prepares *only the licence file's own directory*, non-recursively:

```sh
mkdir -p /data ; chgrp 0 /data ; chmod g+rwxs /data
```

- Group 0 + group-write lets the agent (`2112:0`) create and replace files there.
- `setgid` keeps every file it creates in group 0, so the product containers
  (also `2112:0`) can read it — the chart's existing `2112:0` convention.
- The directory's **owner is unchanged**, and nothing is touched recursively.
- It uses the agent's own image, so there is no extra image to pull, with
  capabilities reduced to `CHOWN`, `FOWNER`, `DAC_OVERRIDE`.

The agent itself then runs `runAsNonRoot: true`, `runAsUser: 2112`,
`runAsGroup: 0`, `readOnlyRootFilesystem: true`, `capabilities: drop [ALL]`.

**Why not `podSecurityContext.fsGroup`?** It is ignored on hostPath PVs (the
`local` target) and on NFS/EFS, and where it *is* honoured the kubelet
recursively chowns the whole volume on every pod start — a non-starter for a
multi-terabyte `/data`.

If you would rather pre-create and chown the directory out of band, turn the
initContainer off with `licenseAgent.prepareDataDir.enabled: false`.

If you would rather not have `/data` itself group-writable, put the licence in a
subdirectory and point the readers at it — the initContainer then prepares only
that subdirectory:

```yaml
licenseAgent:   { enabled: true, licenseFile: licensing/cheese_license_file.json }
database:       { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
orchestrator:   { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
alignment:      { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
```

Leave `licenseAgent.licenseFile` empty (the default) and the agent inherits
`database.secret.cheeseLicenseFile`, so the writer and the readers cannot drift
apart by accident.

## Operating it

```bash
kubectl -n cheese logs deploy/cheese-license-agent -c agent
# 2026-08-28 11:39:24 INFO license file renewed: expires 2026-09-27 (contract 2027-08-28)

kubectl -n cheese port-forward deploy/cheese-license-agent 8080:8080
curl -s localhost:8080 | jq
# {"state":"ok","activation_id":"act_…","license_expires_at":"2026-09-27", …}
```

The pod's **READY** column is the quickest signal: the health endpoint answers
200 only while a fresh licence is on disk, and 503 while activating, erroring or
unable to reach the server.

There is deliberately **no livenessProbe**. The endpoint reports 503 during an
outage, and restarting the agent then would throw away its retry backoff for no
benefit — the licence on disk stays valid for ~30 days, which is the whole point
of the grace window. Do not add one.

`replicas` is fixed at 1 with strategy `Recreate`: the agent is the single writer
of the licence file.

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `403 … /api/v1/namespaces/kube-system` in the log | the Role/RoleBinding is missing or the pod uses a different ServiceAccount | check `licenseAgent.rbac.create` / `serviceAccount.name`; try `rbac.scope: cluster` |
| `401 partner_token_not_a_license_key` | a `DMCH-PTN-…` partner token was used as the licence key | use the `DMCH-…` key; mint one for the end-customer with the partner token |
| `activation limit reached` / `409` | `max_activations` slots are all in use | the log prints the live activations; release the stale one, or ask for more slots |
| `licensing server unreachable (grace continues)` | no outbound HTTPS, or the server is down | no immediate impact — the licence on disk is valid for ~30 days; fix egress |
| `Permission denied` writing the licence file | `prepareDataDir.enabled: false` and the directory was never prepared | re-enable it, or `chgrp 0` + `chmod g+rwxs` the directory yourself |
| product still reports a licence error | that image predates the v1 verifier — see the status box at the top | run a verifier-branch image, or keep using the v0 file |
| `ImagePullBackOff` | nothing has been published to the agent's ECR repository yet | build it from `dmch-licensing` and side-load it (below) |

## The image

The agent is published to its own, **product-agnostic** namespace:

```
815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/licensing/dmch-licensing-agent
```

Not `on-prem/cheese/…` like every other image this chart pulls. There is one
agent for all DeepMedChem on-prem products, so it sits beside them rather than
inside CHEESE's namespace, and every product's customer pull role is granted
`on-prem/licensing/*` on top of its own namespace. Channel tags follow the same
convention as the product images — `:develop` and `:latest`, selected with
`onprem.imageTag` — plus an immutable `:<short-sha>` for tracing a running pod
back to a commit.

> **⚠️ Nothing is published there yet.** The repository is created by
> [terraform-deepmedchem#82](https://github.com/Deep-MedChem/terraform-deepmedchem/pull/82)
> and filled by `publish-agent-image.yml` in `dmch-licensing`. Until that
> Terraform is **applied** and the first build has run, `source: ecr` gets
> `ImagePullBackOff`. Build and side-load instead:

```bash
# in dmch-licensing/
docker build -f licensing/agent/Dockerfile -t dmch-licensing-agent:dev .
kind load docker-image dmch-licensing-agent:dev --name <cluster>   # or push to your own registry
```

```yaml
licenseAgent:
  image:
    source: local
    local: { repository: dmch-licensing-agent, tag: dev, pullPolicy: Never }
```

> **Renamed.** The side-load tag was `cheese-license-agent` and is now
> `dmch-licensing-agent`, matching the published artifact and the ongoing
> `CHEESE_LICENSING_*` → `DMCH_LICENSING_*` rename. If you have the old image on
> a node, `docker tag cheese-license-agent:dev dmch-licensing-agent:dev` (and
> reload it) — or just set `local.repository` back in your own values file. The
> in-cluster object names (`Deployment/cheese-license-agent` and friends) are
> **unchanged**; only the image tag moved.

## Verify without a cluster

```bash
cd k8s
helm lint charts/cheese
# nothing agent-shaped may render by default
helm template cheese charts/cheese | grep -c license-agent          # → 0
# inline key
helm template cheese charts/cheese --set licenseAgent.enabled=true \
  --set licenseAgent.secret.licenseKey=DMCH-EXAMPLE \
  --show-only templates/license-agent-deployment.yaml
# external secret — must render NO Secret and reference yours
helm template cheese charts/cheese --set licenseAgent.enabled=true \
  --set licenseAgent.secret.existingSecret=cheese-license-key
# cluster-scoped RBAC variant, and the aws target
helm template cheese charts/cheese --set licenseAgent.enabled=true \
  --set licenseAgent.secret.licenseKey=DMCH-EXAMPLE --set licenseAgent.rbac.scope=cluster
helm template cheese charts/cheese --set licenseAgent.enabled=true \
  --set licenseAgent.secret.licenseKey=DMCH-EXAMPLE --set deployment.target=aws
```

> **Rendering and applying by hand?** `helm template` does not stamp a namespace
> onto namespaced objects, so `kubectl apply -n cheese -f rendered.yaml` refuses
> the `kube-system` Role with *"the namespace from the provided object
> kube-system does not match"*. Apply that file without `-n`, or just use
> `helm install`/`helm upgrade`, which handles it correctly.

## Notes for whoever maintains this

- The agent's environment variables are `CHEESE_*` on purpose. The **server**
  side was renamed to `DMCH_LICENSING_*`; the **client** side is the deployed
  product's existing contract and was deliberately left alone. Do not "fix" them.
- `CHEESE_ACTIVATION_ID` belongs to the **product** containers, not the agent: it
  is an optional soft cross-check inside the v1 verifier, and a mismatch only
  logs a warning. Activation limits are enforced server-side.
- Off-cluster (Compose, bare metal) the same agent binary uses a persisted UUID
  as its fingerprint instead of the namespace UID; that path is documented in
  the Compose install docs, not here.
- `licenseAgent.fingerprintOverride` exists for tests only. Setting it in a real
  install burns an activation slot on a fingerprint you cannot reproduce.
