# The licence agent on Kubernetes <kbd>☸️ k8s</kbd> <kbd>🌐 v1 licensing</kbd>

The chart can run a small **licence agent** next to the stack. It exchanges the
`DMCH-…` licence key you were issued for a signed licence file, writes that file
onto the shared `/data` PVC at exactly the path the product containers read, and
renews it daily — so nobody has to hand-install or refresh a licence file.

It is **optional and off by default** (`licensingAgent.enabled: false`). With it
off, the chart behaves exactly as before: you place a licence file on the PVC
yourself.

> ### ⚠️ Read this before you rely on it
>
> **Not every image understands v1.** An image that supports it dispatches on
> the licence's `schema` field and leaves the v0 path untouched, so a
> hand-placed v0 file and an agent-written v1 file both verify. An image that
> predates the scheme rejects a v1 file as **"signature does not match license
> content"** — the signature is fine, the image simply cannot read that schema.
>
> The two core components the chart enables by default (`cheese-database`,
> `cheese-orchestrator`) support v1. The optional ones may lag. Which release of
> which image supports v1 changes as images ship, so confirm with DeepMedChem
> for the components you intend to enable rather than assuming — this document
> is not the place that tracks it.
>
> **The agent's image tag is pinned by the chart** and deliberately does not
> follow `onprem.imageTag`: the agent versions independently of the CHEESE
> product images. See [Enable it](#enable-it).

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
kubectl -n cheese create secret generic dmch-license-key \
  --from-literal=licenseKey='DMCH-…'
```

```yaml
licensingAgent:
  enabled: true
  serverUrl: https://licensing.deepmedchem.com
  secret:
    existingSecret: dmch-license-key      # any Secret with a `licenseKey` key
```

`existingSecret` is the same convention the other components use, so Vault,
External Secrets Operator, SealedSecrets or a plain pre-created Secret all work.
The chart then renders **no** Secret of its own.

### Self-contained (inline)

```yaml
licensingAgent:
  enabled: true
  secret:
    licenseKey: "DMCH-…"        # rendered into Secret `dmch-license-key`
```

Keep that in your gitignored secrets values file (see
[`../charts/cheese/values-secrets.yaml.example`](../charts/cheese/values-secrets.yaml.example)).

### What gets created

| Object | Namespace | Purpose |
|---|---|---|
| `Deployment/dmch-licensing-agent` | release ns | 1 replica, `Recreate` — single writer of the licence file |
| `ServiceAccount/dmch-licensing-agent` | release ns | identity used to read the fingerprint |
| `Secret/dmch-license-key` | release ns | only when `secret.existingSecret` is empty |
| `Role` + `RoleBinding` `<release>-licensing-agent-fingerprint` | **`kube-system`** | the single API permission (see below) |

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
licensingAgent:
  rbac:
    scope: cluster        # ClusterRole + ClusterRoleBinding, resourceNames: [kube-system]
```

`resourceNames` do not apply to `list`/`watch`, so that variant does not grant
listing either. To wire RBAC entirely yourself:

```yaml
licensingAgent:
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
initContainer off with `licensingAgent.prepareDataDir.enabled: false`.

If you would rather not have `/data` itself group-writable, put the licence in a
subdirectory and point the readers at it — the initContainer then prepares only
that subdirectory:

```yaml
licensingAgent:   { enabled: true, licenseFile: licensing/cheese_license_file.json }
database:       { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
orchestrator:   { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
alignment:      { secret: { cheeseLicenseFile: licensing/cheese_license_file.json } }
```

Leave `licensingAgent.licenseFile` empty (the default) and the agent inherits
`database.secret.cheeseLicenseFile`, so the writer and the readers cannot drift
apart by accident.

## Operating it

```bash
kubectl -n cheese logs deploy/dmch-licensing-agent -c agent
# 2026-08-28 11:39:24 INFO license file renewed: expires 2026-09-27 (contract 2027-08-28)

kubectl -n cheese port-forward deploy/dmch-licensing-agent 8080:8080
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
| `403 … /api/v1/namespaces/kube-system` in the log | the Role/RoleBinding is missing or the pod uses a different ServiceAccount | check `licensingAgent.rbac.create` / `serviceAccount.name`; try `rbac.scope: cluster` |
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
`on-prem/licensing/*` on top of its own namespace. Alongside the released tag
there is an immutable `:<short-sha>` for tracing a running pod back to a commit.

The agent's tag is **pinned in the chart** and is not taken from
`onprem.imageTag`: that value selects the CHEESE product channel, and the agent
versions on its own schedule. Setting `licensingAgent.image.ecr.tag` to `""`
would fall back to the product channel and ask for an agent build that need not
exist.

To iterate on a locally built agent instead of pulling one, side-load it:

```bash
# in dmch-licensing/
docker build -f licensing/agent/Dockerfile -t dmch-licensing-agent:dev .
kind load docker-image dmch-licensing-agent:dev --name <cluster>   # or push to your own registry
```

```yaml
licensingAgent:
  image:
    source: local
    local: { repository: dmch-licensing-agent, tag: dev, pullPolicy: Never }
```

## Verify without a cluster

```bash
cd k8s
helm lint charts/cheese
# nothing agent-shaped may render by default
helm template cheese charts/cheese | grep -c licensing-agent          # → 0
# inline key
helm template cheese charts/cheese --set licensingAgent.enabled=true \
  --set licensingAgent.secret.licenseKey=DMCH-EXAMPLE \
  --show-only templates/licensing-agent-deployment.yaml
# external secret — must render NO Secret and reference yours
helm template cheese charts/cheese --set licensingAgent.enabled=true \
  --set licensingAgent.secret.existingSecret=dmch-license-key
# cluster-scoped RBAC variant, and the aws target
helm template cheese charts/cheese --set licensingAgent.enabled=true \
  --set licensingAgent.secret.licenseKey=DMCH-EXAMPLE --set licensingAgent.rbac.scope=cluster
helm template cheese charts/cheese --set licensingAgent.enabled=true \
  --set licensingAgent.secret.licenseKey=DMCH-EXAMPLE --set deployment.target=aws
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
- `licensingAgent.fingerprintOverride` exists for tests only. Setting it in a real
  install burns an activation slot on a fingerprint you cannot reproduce.
