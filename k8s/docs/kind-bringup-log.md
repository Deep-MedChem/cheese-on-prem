# First-time kind bringup — as actually run

This is the log of the steps we ran end-to-end to bring up the `cheese` chart
on a developer laptop running kind. It is a *record of what worked*, not a
template — for the canonical playbook see [`install-order.md`](./install-order.md)
and for PVC contents [`pvc-data-runbook.md`](./pvc-data-runbook.md).

The session is annotated with the gotchas we hit so the next person doesn't
have to re-discover them.

## 0. Layout assumed

All four upstream repos cloned alongside `cheese-k8s/`:

```
DeepMedChem/
├── cheese-k8s/                 ← this repo
├── cheese-orchestrator/
├── cheese-database/
├── cheese-search-ui/
└── synthongpt-prod/
```

All commands below are run from inside `cheese-k8s/`.

## 1. Cluster + ingress

```bash
kind create cluster --config kind/cluster.yaml
make install-ingress-controller
```

`kind/cluster.yaml` already maps host ports 80/443 into the kind node, so
`*.localtest.me` resolves through the host's loopback.

## 2. Namespace + PV + PVC

```bash
kubectl apply -f manifests/base/namespace.yaml
kubectl apply -f manifests/base/persistent-volume.local-example.yaml
kubectl apply -f manifests/base/persistent-volume-claim.yaml
kubectl -n cheese get pvc cheese-data-pvc        # STATUS should be Bound
```

> **kind hostPath gotcha.** The PV uses `hostPath: /data`. With kind on Linux,
> "host" is the `kind-control-plane` Docker container, **not** your laptop.
> Anything you put in `/data` on the laptop is invisible to pods. Stage data
> with `docker cp ... kind-control-plane:/data/...` and run chown via
> `docker exec kind-control-plane ...`. On a real on-prem node (no kind
> layer), `/data` on the host *is* the path the pods see.

Create `/data` inside the kind node and own it for the chart's UID 2112:

```bash
docker exec kind-control-plane sh -c \
  'mkdir -p /data && chown 2112:0 /data && chmod 0775 /data'
```

## 3. Images

We pre-built / pre-tagged four images and loaded them into kind:

```bash
# search-ui can be built locally without ACR access (Dockerfile uses public bases):
BUILD="cheese-search-ui" make build-source-images
LOAD="cheese-search-ui-local" make load-images

# orchestrator + database + synthongpt — Dockerfile-on-prem in those repos
# uses `FROM cheese.azurecr.io/...:base`, so a fresh `docker build` needs ACR
# auth. We had previously pulled the customer images from ACR; tagging those
# as *-local:dev is enough for the chart's image.source: local path:
docker tag cheese.azurecr.io/on-prem/cheese-orchestrator/cheese-customer:latest cheese-orchestrator-local:dev
docker tag cheese.azurecr.io/on-prem/cheese-database/cheese-customer:latest    cheese-database-local:dev
docker tag cheese.azurecr.io/on-prem/cheese-synthongpt/cheese-customer:latest  cheese-synthongpt-local:dev

for img in cheese-orchestrator-local:dev cheese-database-local:dev cheese-synthongpt-local:dev; do
  kind load docker-image "$img" --name kind
done
```

> If you have ACR creds and prefer fresh builds, run the per-service
> `docker build -f .../Dockerfile-on-prem` calls instead — same end state.

## 4. License (must run inside the kind cluster)

The license file is keyed to the host hardware that *runs the database
container*. On kind, that's the `kind-control-plane` container, not your
laptop, so a license generated from the host won't validate. Run the keygen
as a one-shot pod on the cluster:

```bash
kubectl run -n cheese cheese-license-keygen \
  --rm -it --restart=Never \
  --image=cheese-database-local:dev \
  --image-pull-policy=IfNotPresent \
  --overrides='{"spec":{"containers":[{"name":"cheese-license-keygen","image":"cheese-database-local:dev","imagePullPolicy":"IfNotPresent","workingDir":"/opt/cheese/cheese_database","command":["python","-c","from generate_license_ID import main; print(\"Your license key is\"); main()"],"stdin":true,"tty":true}]}}'
```

Send the printed key to support; they return a JSON license file. Drop it
into the kind node:

```bash
docker cp cheese_license_file.json kind-control-plane:/data/cheese_license_file.json
docker exec kind-control-plane chown 2112:0 /data/cheese_license_file.json
```

The license filename is referenced from the chart's secrets file as
`database.secret.cheeseLicenseFile` and `orchestrator.secret.cheeseLicenseFile`;
both components read the same file, so the value must match in both blocks.

## 5. Stage the test database

Until you have a real database tree, the small built test DB shipped with
`cheese-on-prem` is enough to bring up `cheese-database-app`:

```bash
docker cp cheese-on-prem/tests/test_db/. kind-control-plane:/data/test_database/
docker exec kind-control-plane chown -R 2112:0 /data/test_database
```

The chart's `values-onprem.yaml` declares this DB:

```yaml
database:
  databases:
    test_database:
      enabled: true
      output_directory: "test_database"
      index_type: "Flat"
      delimiter: ","
```

(SynthonGPT data was deliberately not staged — only `/search` and
`/database_info` calls hit SynthonGPT, and we accepted the synthongpt pod
crashlooping for this run.)

## 6. Fill in values + install

```bash
cp charts/cheese/values-onprem.yaml.example  charts/cheese/values-onprem.yaml
cp charts/cheese/values-secrets.yaml.example charts/cheese/values-secrets.yaml
$EDITOR charts/cheese/values-{onprem,secrets}.yaml
```

Secrets you need real values for:

| Block                                             | What                                       |
|---------------------------------------------------|--------------------------------------------|
| `database.secret.production`                      | OUR_SECRET-style value (decrypts models)   |
| `database.secret.cheeseLicenseFile`               | filename on the PVC, e.g. `cheese_license_file.json` |
| `orchestrator.env.production`                     | must match `database.secret.production`    |
| `orchestrator.secret.cheeseLicenseFile`           | same filename as above                     |
| `orchestrator.supabase.serviceRoleKey`            | Supabase API → service_role                |
| `searchUi.secret.{cheeseUiUserSecret,supabaseAnonKey,supabaseServiceRoleKey,viteSupabaseAnonKey}` | UI auth + Supabase keys |

Install:

```bash
helm install cheese charts/cheese \
  --namespace cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml
```

## 7. Verify

```bash
kubectl -n cheese get pods
kubectl -n cheese rollout status deploy/cheese-orchestrator
kubectl -n cheese rollout status deploy/cheese-search-ui
```

Expected at the end of *this* run (with placeholder Supabase keys and no
real PRODUCTION secret):

| Pod                      | Status              | Why                                                     |
|--------------------------|---------------------|---------------------------------------------------------|
| `cheese-search-ui`       | Running             | reachable at `http://cheese-ui.localtest.me`            |
| `cheese-orchestrator`    | Running, /health 200| reads license from `/data` once the chart was patched   |
| `cheese-database-*` (4)  | CrashLoopBackOff    | needs real `PRODUCTION` to decrypt the bundled cheese-models.zip, or pre-decrypted models on `/data/models/` |
| `cheese-synthongpt`      | CrashLoopBackOff    | no checkpoint tree on `/data/synthongpt_data/` (intentional) |

The Supabase 500s on `/available_databases_full` are also expected with
`REPLACE_ME` keys — fix by pasting real Supabase service-role + anon keys
into `values-secrets.yaml` and `helm upgrade`.

## 8. Reinstall after a code or values change

For values only:

```bash
helm upgrade cheese charts/cheese -n cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml
```

For an image rebuild, rebuild + reload + bounce the deployment:

```bash
BUILD="cheese-orchestrator" make build-source-images
LOAD="cheese-orchestrator-local" make load-images
kubectl -n cheese rollout restart deploy/cheese-orchestrator
```

## 9. Gotchas we hit, in case they recur

- **Resource names are hardcoded.** Deployments, Services, ConfigMaps,
  Secrets, and Ingresses use literal names (`cheese-database-app`,
  `cheese-orchestrator`, …) regardless of release name. The orchestrator's
  default service URLs (`cheese-database-app.cheese.svc.cluster.local`)
  depend on those names; don't try to make them templatable.
- **Stale namespaces from a previous raw-manifest install** can grab the
  ingress hostname. We fixed it once with
  `kubectl delete namespace cheese-ui --wait=true`.
- **Orphaned helm release secret** after a failed install — `helm list -A`
  will show a release in failed state. Clean with `helm uninstall <name>`
  before retrying.
- **License said "not a valid cheese license"** when the JSON was generated
  on the laptop instead of on the kind node. Always run the keygen as a
  pod inside the cluster (Step 4).
- **`/data/None` from the orchestrator** — chart used to omit the
  `CHEESE_LICENSE_FILE` env and the `/data` PVC mount; both are now wired in
  `charts/cheese-orchestrator/templates/deployment.yaml`. If you see this
  again, that template regressed.
