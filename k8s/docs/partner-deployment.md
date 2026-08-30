# Deploying CHEESE on your Kubernetes cluster

<kbd>👤 partner</kbd> <kbd>☸️ kubernetes</kbd> <kbd>⭐ single helm install</kbd>

This is the whole deployment: two product components, the databases, and the
licence, brought up by one `helm install`. Read
[the k8s README](../README.md) first for what the chart contains; this page is
the sequence.

## What DeepMedChem gives you

| | What | Used for |
|---|---|---|
| 🔑 | An **AWS access key** (`AKIA…` + secret) | pulling the images **and** downloading the databases — one key does both |
| 📄 | A **licence key** (`DMCH-…`) | the licence agent exchanges it for a licence file and keeps it renewed |

The access key carries no permissions of its own — its only right is assuming a
read-only role. So the worst case if it leaks is that someone downloads the
images and databases you are already licensed for.

> A `DMCH-PTN-…` **partner token is not a licence key.** If you were given one,
> it issues licence keys for *your* end-customers via the partner API; each
> deployment still needs its own `DMCH-…` key. Putting the partner token in the
> licence secret fails immediately with `partner_token_not_a_license_key`.

## What you provide

- A **PersistentVolume** the chart binds as `cheese-data-pvc`. Size it for the
  databases you choose — they run from under 1 GB to about 1.3 TB each, ~8 TB for
  the whole catalogue. Add ~10% headroom.
- Outbound **HTTPS to AWS `us-east-1`** (ECR for images, S3 for databases) and to
  the licensing service. Nothing inbound.

## 1. Store the credentials as Secrets

The AWS key goes in a Secret the chart reads. The `cheese` CLI writes the right
shape for you — run it from wherever you use `kubectl`:

```bash
cheese aws-auth --target k8s --namespace cheese
```

It verifies the key against AWS *before* storing it, so a typo or an
unentitled key is caught here rather than as an `ImagePullBackOff` later. If you
manage secrets with Vault / External Secrets / SealedSecrets, use
`--target print` to get the manifest and feed it to your own pipeline instead.

Then the image-pull Secret, which is a different format (a docker-registry
Secret the kubelet uses):

```bash
kubectl create secret docker-registry cheese-ecr-pull -n cheese \
  --docker-server=815935788477.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)"
```

> ### ⚠️ This one expires in 12 hours
>
> An ECR login token is valid for 12 hours. The Secret above works today and then
> fails the next time a pod is rescheduled, as an `ImagePullBackOff` that looks
> nothing like an expiry. Pick one:
>
> - **On EKS** — give the node role ECR pull permission and let the built-in
>   credential provider handle it. No Secret, nothing to expire. Best option.
> - **Anywhere else** — refresh it on a schedule (a CronJob re-running the
>   command above, or External Secrets pointed at the token).
>
> The chart consumes the Secret by name and does not refresh it.

## 2. Install

```yaml
# my-values.yaml
onprem:
  imageTag: develop              # or `latest`; the channel for the CHEESE images

database:
  image:
    source: ecr
  # Which databases the engine serves. dataSync fetches exactly these, so the
  # data on the volume and the engine's config cannot drift apart.
  databases:
    ZINC15:
      enabled: true
      output_directory: "zinc15"
      index_type: "clustered"
      delimiter: ","

orchestrator:
  image:
    source: ecr

# Fetch the databases onto the volume.
dataSync:
  enabled: true

# Keep the licence fresh.
licensingAgent:
  enabled: true
  image:
    source: ecr
    ecr:
      tag: latest                # REQUIRED: the agent has no :develop build yet
  secret:
    licenseKey: "DMCH-…"         # or secret.existingSecret: <your-secret>
```

> Note both `database` keys live in **one** block above. YAML silently keeps only
> the last mapping for a duplicated key, so splitting `database.image` and
> `database.databases` into two top-level `database:` entries drops one of them —
> and the symptom is an image that quietly stays on its default instead of an
> error.

```bash
helm install cheese charts/cheese -n cheese --create-namespace -f my-values.yaml
```

That is the whole deployment. `database` and `orchestrator` are enabled by
default and are the only components you need; everything else in the chart is
optional and off.

## 3. Watch it come up

```bash
kubectl -n cheese get pods
kubectl -n cheese logs -f job/cheese-cheese-data-sync     # database download
kubectl -n cheese logs -f deploy/dmch-licensing-agent     # licence activation
```

**The database pods will restart until the sync finishes.** That is expected: the
sync is a Job running alongside the stack, not a gate in front of it, because a
multi-hundred-GB download would otherwise make `helm install` appear hung for
hours. `aws s3 sync` is incremental — if it is interrupted, or you add a database
later, re-running fetches only what is missing.

Once data is present and the licence file has been written, the API answers on
the orchestrator's ingress.

## Notes

- **Databases and the licence share one volume.** The agent writes the licence
  file to the same PVC the databases live on, and the product containers read
  both as UID 2112. The chart prepares only the directories it needs, group 0 +
  setgid — never a recursive `chown` of a multi-terabyte volume.
- **One licence covers the whole cluster.** The fingerprint is your cluster's
  `kube-system` namespace UID, so nodes can come and go freely. Running several
  releases in one cluster does **not** need several licences — they share that
  fingerprint. (If you are a platform partner serving many end-customers from one
  cluster, that is one licence plus your own per-user separation, not one licence
  per user.)
- **Air-gapped clusters are not supported.** The v0 offline licence binds to a
  single machine's hardware id, which cannot hold across a cluster whose nodes
  change. Kubernetes uses the agent-renewed v1 licence, which needs a daily
  check-in with ~29 days of margin.

## ⚠️ Current limitations

- **Pin the licence agent to `ecr.tag: latest`.** The agent image is published,
  but only `:latest` exists so far. Left on the tag inherited from
  `onprem.imageTag` (`develop`) it does not resolve and the agent sits in
  `ImagePullBackOff`. The agent's release channel is separate from the CHEESE
  product channel, so pin it deliberately:

  ```yaml
  licensingAgent:
    enabled: true
    image:
      source: ecr
      ecr:
        tag: latest
  ```

- **Two optional components cannot run on a v1 licence yet.**
  `cheese-inference` and `conformer-alignment-api` still verify v0 only; their
  verifier ports are open. The two components you actually need
  (`cheese-database`, `cheese-orchestrator`) enforce v1 and are unaffected.
- **Four optional images have no `:develop` tag** (`ketcher`, `cheese-inference`,
  `cheese-electrostatics-inference`, and the licence agent above). With
  `onprem.imageTag: develop` they will not resolve — pin them to `latest` with
  their own `ecr.tag` if you enable them.
