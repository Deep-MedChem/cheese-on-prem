# Runbook — PVC data layout

The five data-plane pods (`cheese-database-{app,jobs-db,jobs-exec,download-exec}`
and `cheese-synthongpt`) all mount one shared `cheese-data-pvc` at `/data`.
**The data on this volume is loaded out-of-band, not by Helm.** This runbook is
the authoritative description of what the charts expect to find there.

## Layout at a glance

```
/data/
├── cheese_license_file.json                  # cheese-database — license file
├── jobs/                                     # cheese-database — auto-created by jobs/exec roles
│   └── ...                                   #   (empty at install time)
├── <db_name>/                                # cheese-database — one per .Values.databases entry
│   └── ...                                   #   (per-database files; format set by index_type)
└── synthongpt_data/                          # cheese-synthongpt — SYNTHONGPT_DATA_ROOT
    ├── outputs/multidb/fixed/best.pt
    ├── data/
    │   ├── indexes/multidb/multidb_synthon_morgan2048.pt
    │   ├── molecules/multidb/reactions.txt
    │   └── models/chemeleon_mp.pt            # optional (only if checkpoint uses Chemeleon)
    └── ...
```

The exact subpaths under `<db_name>/` and `synthongpt_data/` come from upstream
data drops; this runbook covers the boundary the charts assume.

## 1. Bootstrap (one-time)

The kind PV uses `hostPath: /data` (see
`manifests/base/persistent-volume.local-example.yaml`) — same path the
production VMs use, so the application's view of `/data` is identical across
kind / dev / prod.

> **Kind gotcha.** With kind on Linux, the cluster "node" is itself a Docker
> container (`kind-control-plane`). hostPath resolves *inside* that container,
> not on your laptop, so creating `/data` on the host does nothing for the
> pods. Use `docker exec kind-control-plane …` and `docker cp … kind-control-plane:/data/…`.
> On a real on-prem node (no kind layer), drop the `docker exec` prefix and
> work on `/data` directly.

```bash
# Create /data on the kind node (one-time):
docker exec kind-control-plane sh -c \
  'mkdir -p /data && chown 2112:0 /data && chmod 0775 /data'

# Apply the namespace, PV, and PVC manifests (run from inside cheese-k8s/):
kubectl apply -f manifests/base/namespace.yaml
kubectl apply -f manifests/base/persistent-volume.local-example.yaml
kubectl apply -f manifests/base/persistent-volume-claim.yaml

# Verify:
kubectl -n cheese get pvc cheese-data-pvc       # STATUS should be Bound
```

If the PVC stays `Pending`, the PV's `storageClassName` and the PVC's must
match (`cheese-local-manual` in the example), and the host path must exist.

## 2. cheese-database — required files

### License file

```
/data/license.yaml
```

The filename is set by `database.secret.cheeseLicenseFile` in
`charts/cheese/values.yaml` (default `cheese_license_file.json`). The container
reads it at `/data/<filename>` per `CHEESE_LICENSE_FILE`.

Skip this file if you set `secret.cheeseLicense` (inline license) in
`values-secrets.yaml` instead.

### Database files (one tree per `.Values.databases` entry)

For every entry `<name>` under `database.databases` in
`charts/cheese/values-onprem.yaml`:

```yaml
database:
  databases:
    enamine_real_diverse:
      enabled: true
      output_directory: "enamine_real_diverse"
      index_type: "IVF"
      delimiter: " "
```

…the chart's ConfigMap renders `OUTPUT_DIRECTORIES.enamine_real_diverse: "enamine_real_diverse"`,
and the `cheese-database` code reads files from `/data/enamine_real_diverse/`.
The actual files inside that directory are produced by the upstream
`cheese-database` build pipeline; place them on the PVC before pods start.

### Adding a new database (recurring task)

This is the "established and relatively simple routine" the chart was designed
for. Three steps:

```bash
# 1. Stage the data on the kind node (or, on prod, the host directly):
docker cp /path/to/<db_name> kind-control-plane:/data/<db_name>
docker exec kind-control-plane chown -R 2112:0 /data/<db_name>

# 2. Add the entry to charts/cheese/values-onprem.yaml:
#    database:
#      databases:
#        <db_name>:
#          enabled: true
#          output_directory: "<db_name>"
#          index_type: "Flat"     # or IVF, HNSW, …
#          delimiter: ","

# 3. helm upgrade — the ConfigMap re-renders, pods restart and pick it up:
helm upgrade cheese charts/cheese -n cheese \
  -f charts/cheese/values-onprem.yaml \
  -f charts/cheese/values-secrets.yaml
```

To remove a database, set `enabled: false` (keeps the data on disk) or delete
the entry entirely (also drop the on-disk directory if you want the space back).

### `jobs/` directory

`cheese-database-jobs-exec` and `-download-exec` create files under
`/data/jobs/` at runtime (`JOBS_DATA_PATH=jobs` in values). No manual setup
needed; the directory is created on first use. If you want a different
location, change `env.jobs_data_path` and the workers will use that instead.

## 3. cheese-synthongpt — required files

The `synthongpt_data/` subtree is rooted at `SYNTHONGPT_DATA_ROOT`, which the
chart computes as `<data.mountPath>/<dataRootSubdir>` (default
`/data/synthongpt_data`).

### Required (the API exits at startup if any are missing)

| Path under `/data/synthongpt_data/`                                   | CLI flag default     |
|-----------------------------------------------------------------------|----------------------|
| `outputs/multidb/fixed/best.pt`                                       | `--checkpoint`       |
| `data/indexes/multidb/multidb_synthon_morgan2048.pt`                  | `--synthon-index`    |
| `data/molecules/multidb/reactions.txt`                                | `--reactions`        |

### Optional (loaded lazily; missing = feature off)

| Path                                                                  | CLI flag                  |
|-----------------------------------------------------------------------|---------------------------|
| `data/models/chemeleon_mp.pt`                                         | `--chemeleon`             |
| `data/indexes/multidb/multidb_synthon_stripped_cache.pt`              | `--stripped-synthon-cache`|
| `synthon_bench_search/data/outside_queries.smi`                       | `--random-smiles-file`    |

To point at non-default paths, add `synthongpt.runtime.extraArgs` in
`charts/cheese/values-onprem.yaml`:

```yaml
synthongpt:
  runtime:
    extraArgs:
      - "--checkpoint"
      - "/data/synthongpt_data/outputs/custom/best.pt"
```

### Staging the data

```bash
# kind: copy into the node container.
docker cp /path/to/synthongpt_data  kind-control-plane:/data/synthongpt_data
docker exec kind-control-plane chown -R 2112:0 /data/synthongpt_data

# prod: drop the docker prefix and operate on /data on the host directly.
```

## 4. Permissions cheat-sheet

All chart pods run as UID `2112`, group `0`, with all Linux capabilities
dropped. Files on the PVC must be readable by that identity:

```bash
# Quick fix when something is unreadable (kind):
docker exec kind-control-plane chown -R 2112:0 /data
docker exec kind-control-plane chmod -R u+rwX,g+rwX,o+rX /data
# On prod (no kind layer), run those chown/chmod on the host directly.
```

Datasets only need read; write access is required for `/data/jobs/` (workers)
and any path the licensing path writes to.

## 5. Verification

After helm install, sanity-check from inside the cluster:

```bash
# License file landed where cheese-database expects it:
kubectl -n cheese exec deploy/cheese-database-app -- \
  ls -l /data/cheese_license_file.json

# A configured database is visible under /data:
kubectl -n cheese exec deploy/cheese-database-app -- \
  ls /data/enamine_real_diverse

# SynthonGPT can see the checkpoint:
kubectl -n cheese exec deploy/cheese-synthongpt -- \
  ls /data/synthongpt_data/outputs/multidb/fixed/best.pt

# /health endpoints respond:
kubectl -n cheese exec deploy/cheese-orchestrator -- \
  curl -sf http://cheese-database-app:8001/health
kubectl -n cheese exec deploy/cheese-orchestrator -- \
  curl -sf http://cheese-synthongpt:8000/health
```

A 404 from `/health` on `cheese-synthongpt` means the API is still booting
(the checkpoint load is the slow part); check the pod's logs.

## 6. Where to look in the code

The paths above are not arbitrary — they're hard-coded in:

- `cheese-database/cheese_database/cheese_core.py` — `/data/{CONFIG_FILE}`
- `cheese-database/cheese_database/cheese_license.py` — `/data/{CHEESE_LICENSE_FILE}`
- `cheese-database/cheese_database/jobs_executor.py` — `/data/{JOBS_DATA_PATH}`
- `synthongpt-prod/apps/api/synthon_api.py` — `SYNTHONGPT_DATA_ROOT` and
  `parse_args()` defaults

Changing the on-PVC layout means changing those code sites first; this runbook
will follow.
