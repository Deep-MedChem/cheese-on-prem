# From a test cluster to production <kbd>👤 partner</kbd> <kbd>☸️ kubernetes</kbd>

You have CHEESE working on a throwaway cluster. This is what changes when you
move it somewhere real.

Work top to bottom — later items assume the earlier ones.

---

## <kbd>1</kbd> Storage — the one you cannot retrofit

On kind the volume is a `hostPath` **inside the node container**: it dies with the
cluster and cannot survive a node replacement. Production needs a real
PersistentVolume.

- [ ] **Pick a StorageClass.** `deployment.target: aws` defaults to `gp3` (RWO), or
      `efs-sc` when `deployment.storage.accessMode: ReadWriteMany`. On another
      platform set `deployment.storage.className` explicitly.
- [ ] **RWO or RWX?** `ReadWriteOnce` confines every pod that mounts `/data` to one
      node. To spread search across nodes you need `ReadWriteMany` — decide now,
      because changing it later means moving terabytes.
- [ ] **Size it for the databases you chose, plus ~10%.** Run
      `cheese configure-dbs`, or read `config/databases.catalog`, for exact sizes.
      They range from 655 MB to ~1.2 TB each.
- [ ] **Check your storage backend's throughput.** The first sync writes the whole
      database; a slow or burst-credit-limited volume turns hours into days.

## <kbd>2</kbd> Image pulls — the 12-hour trap

An ECR login token is valid for **12 hours**. A Secret created once works today
and fails the next time a pod is rescheduled, as an `ImagePullBackOff` that looks
nothing like an expiry.

- [ ] **On EKS** — give the node role ECR pull permission and let the built-in
      credential provider handle it. No Secret, nothing to expire. Best option.
- [ ] **Anywhere else** — refresh on a schedule: a CronJob re-running
      `aws ecr get-login-password --profile <yours>` into the Secret, or External
      Secrets pointed at the token.
- [ ] Confirm your cluster's nodes have **outbound HTTPS to `us-east-1`** (ECR, S3,
      STS). Note this is the *nodes*, not your laptop — an egress proxy that your
      workstation bypasses will surface as a pull or sync failure.

## <kbd>3</kbd> Licence — you need a new one

**Your test cluster's licence does not move.** The v1 fingerprint is the cluster's
`kube-system` namespace UID, so a different cluster is a different installation.

- [ ] **Issue a fresh key** for the production cluster:
      `POST /partner/v1/licenses` with a `customer_name` you are happy to keep —
      it is recorded, and unique across all partners.
- [ ] **Revoke the test one** (`POST /partner/v1/licenses/{id}/revoke`) so it stops
      consuming a slot against your quota.
- [ ] **Set `max_activations` deliberately.** The default is 1. It is not a node
      count — one cluster is one activation however many nodes it spans. Raise it
      only if you genuinely run multiple clusters on one key.
- [ ] **Do not set `fingerprintOverride`** in production. It exists for
      delete-and-recreate test loops; pinning it in production defeats the identity
      the licence is bound to.

## <kbd>4</kbd> Secrets — move them out of values files

Every secret-bearing component accepts `secret.existingSecret`, so the chart
renders no Secret of its own and reads yours.

- [ ] Point `licensingAgent.secret.existingSecret` at your Vault / External
      Secrets / SealedSecrets-managed Secret. Same for the database and
      orchestrator blocks.
- [ ] **If you use `orchestrator.secret.existingSecret`, your Secret must contain
      `supabaseServiceRoleKey` and `discordWebhookUrl`** — even if you run neither
      Supabase nor Discord. They are not optional refs, and a missing key surfaces
      as `CreateContainerConfigError`, which does not say which key is missing.
      Empty string values are fine.
- [ ] Keep any inline-secrets values file **gitignored**. See
      `charts/cheese/values-secrets.yaml.example`.

## <kbd>5</kbd> Databases

- [ ] **Choose from `database.databases` in `charts/cheese/values.yaml`.** Every
      database CHEESE delivers is listed there with its download size, all off but
      the smallest. A licence entitles you to all of them; the only question is disk.
- [ ] **Enable them in YOUR values file, by flipping the flag only:**
      ```yaml
      databases:
        MOLPORT:
          enabled: false     # on in values.yaml — turn it off if you don't want it
        XTALPI:
          enabled: true      # 770.7 GiB
      ```
      Do not restate `output_directory`, `index_type` or `delimiter`: Helm merges
      your file over the chart's, so the folder and index details are inherited and
      cannot drift. Retyping the folder name is how you get broken database cards,
      blank molecule counts and `422` on search.
- [ ] **Leave `dataSync.enabled: true`.** Folders are derived from your enabled
      entries, so the data on the volume and the engine's config cannot drift.
- [ ] Expect the database pods to **restart until the sync finishes**. The sync
      runs alongside the stack, not in front of it.
- [ ] To add a database later: enable it, then
      `kubectl delete job <release>-data-sync` and `helm upgrade`. The Job will not
      re-run otherwise — its pod template is immutable and it is annotated
      `helm.sh/resource-policy: keep`. `aws s3 sync` is incremental, so only the
      new database is fetched.

## <kbd>6</kbd> Ingress and TLS

- [ ] Replace `*.localtest.me` with real hostnames in
      `orchestrator.ingress.public.hosts`.
- [ ] Set `deployment.ingress.className` for your controller (`alb` on EKS by
      default, otherwise `nginx` unless you say otherwise).
- [ ] **Terminate TLS.** The chart does not issue certificates — use your existing
      cert-manager / ALB certificate setup.
- [ ] Decide whether the API is internet-facing at all. Nothing about CHEESE
      requires inbound access from outside your network.

## <kbd>7</kbd> Before you call it done

- [ ] `kubectl -n <ns> get pods` — everything `1/1`, restart counts stable.
- [ ] `dmch-licensing-agent` is `1/1`. It goes ready **only** once a valid licence
      is on disk, so this is your licence check.
- [ ] `curl -sf https://<your-host>/health` → `OK`.
- [ ] `curl -sf https://<your-host>/available_databases` lists what you enabled.
- [ ] A real `/molsearch` query returns hits.
- [ ] **Restart the orchestrator once the data is in place.** It freezes its list
      of valid database names at import; if it started before the database was
      answering, searches `422` on a database that plainly exists.

## <kbd>8</kbd> Keep it running

- [ ] **Watch the licence agent.** Its readiness endpoint reports 503 while
      activating, renewing or unreachable. The licence carries ~29 days of margin,
      so alert on sustained failure, not a blip — and do **not** add a liveness
      probe, which would restart it during an outage and throw away its backoff.
- [ ] **Watch the pull-Secret refresher** if you built one. Its failure is silent
      until a pod happens to reschedule.
- [ ] **Back up the volume**, or accept re-downloading. The databases are
      re-fetchable from S3; a multi-TB re-sync is not a quick recovery.
- [ ] Nothing phones home except the licence agent's daily check-in. Molecules you
      search never leave your network.

---

## What not to carry over from the test cluster

| Leave behind | Because |
|---|---|
| `values-kind-smoke.yaml.example` | `hostPath` PV, `localtest.me` ingress, single small database |
| `deployment.storage.createLocalPV: true` | renders a hostPath PV — a real cluster provisions its own |
| `licensingAgent.fingerprintOverride` | test-loop only; defeats the licence identity |
| the test licence key | bound to the test cluster's fingerprint — revoke it |
