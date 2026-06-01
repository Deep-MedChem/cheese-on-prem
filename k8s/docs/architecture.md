# cheese-k8s — Architecture

Pod-level view of the on-prem prototype running on a single-node `kind` cluster.

## Pod diagram

```mermaid
flowchart TD
    User[Browser]
    SB[(Supabase<br/>hosted)]

    subgraph Cluster["kind cluster (single node)"]

        subgraph IngNS["namespace: ingress-nginx"]
            ING[ingress-nginx-controller<br/>pod x1]
        end

        subgraph NS["namespace: cheese"]

            UI[cheese-search-ui<br/>1 pod / 1 container<br/>node:*-slim<br/>port 3001]

            ORCH[cheese-orchestrator<br/>1+ pods / 1 container<br/>python uvicorn<br/>port 8001]

            subgraph DBChart["chart: cheese-database — one image, four roles"]
                direction TB
                DB[cheese-db<br/>1 pod / 1 container<br/>cmd: cheese_database.app<br/>port 8001]
                JDB[cheese-jobs-db<br/>1 pod / 1 container<br/>cmd: cheese_database.jobs_app<br/>port 8001]
                JEX[cheese-jobs-exec<br/>1 pod / 1 container<br/>cmd: cheese_database.jobs_executor<br/>worker, no port]
                DEX[cheese-download-exec<br/>1 pod / 1 container<br/>cmd: cheese_database.download_executor<br/>worker, no port]
            end

            SYN[cheese-synthongpt<br/>1 pod / 1 container<br/>optional<br/>port 8000]

            PVC[(cheese-data-pvc<br/>10Ti, RWO<br/>mounted at /data)]

            CFG[/ConfigMap<br/>cheese-runtime-config<br/>config.yaml<br/>databases map/]
            SEC[/Secret<br/>cheese-runtime-secrets<br/>license, PRODUCTION/]

        end
    end

    User -->|cheese-ui.localtest.me| ING
    User -->|cheese-api.localtest.me| ING
    ING --> UI
    ING --> ORCH

    UI -->|REST| ORCH
    UI -->|JS client| SB

    ORCH -->|HTTP :8001| DB
    ORCH -->|HTTP :8001| JDB
    ORCH -. HTTP :8000 .-> SYN
    ORCH -->|HTTPS| SB

    DB --- PVC
    JDB --- PVC
    JEX --- PVC
    DEX --- PVC
    SYN --- PVC

    CFG -.mounts.-> DB
    CFG -.mounts.-> JDB
    CFG -.mounts.-> JEX
    CFG -.mounts.-> DEX
    SEC -.mounts.-> DB
    SEC -.mounts.-> JDB
    SEC -.mounts.-> JEX
    SEC -.mounts.-> DEX
    SEC -.env.-> ORCH
```

## Pod inventory

Minimal prototype: **7 pods** in two namespaces.

| Namespace       | Workload                  | Pods | Port  | Notes                                                       |
|-----------------|---------------------------|------|-------|-------------------------------------------------------------|
| `ingress-nginx` | `ingress-nginx-controller`| 1    | 80/443| Stock kind ingress controller                               |
| `cheese`        | `cheese-search-ui`        | 1    | 3001  | Node SSR + static                                           |
| `cheese`        | `cheese-orchestrator`     | 1+   | 8001  | FastAPI; talks to Supabase + db services                    |
| `cheese`        | `cheese-db`               | 1    | 8001  | `cheese_database.app`                                       |
| `cheese`        | `cheese-jobs-db`          | 1    | 8001  | `cheese_database.jobs_app`                                  |
| `cheese`        | `cheese-jobs-exec`        | 1    | —     | `cheese_database.jobs_executor` worker                      |
| `cheese`        | `cheese-download-exec`    | 1    | —     | `cheese_database.download_executor` worker                  |

With SynthonGPT enabled: **+1 pod** (`cheese-synthongpt`, port 8000).

## Notes

- The four database pods run from one image (`cheese-database`); only `command:` differs. Two roles expose Services (`cheese-db`, `cheese-jobs-db`); the two `*-exec` workers have no Service.
- All five data-plane pods (`cheese-db`, `cheese-jobs-db`, `cheese-jobs-exec`, `cheese-download-exec`, `cheese-synthongpt`) mount the single `cheese-data-pvc` at `/data`. `ReadWriteOnce` is fine on the prototype because every data-plane pod is pinned to the single kind node.
- **Supabase is the only external dependency.** No standalone Postgres, no Keycloak. The orchestrator's psycopg2 path is dead code in the active runtime; the chart's `POSTGRES_*` env block is a vestigial cleanup item, not a live dependency.
- Orchestrator reads SynthonGPT via `SYNTHONGPT_API_URL=http://cheese-synthongpt.cheese.svc.cluster.local:8000` (consumed by `cheese_orchestrator/cheese_core.py`).

## Chart shape (summary)

All four components are Helm charts under `charts/`. The non-obvious one is `cheese-database`: it's an extension of the upstream chart with two new top-level value blocks.

```yaml
roles:
  app:           { enabled: true, command: ["python","-um","cheese_database.app"],              port: 8001 }
  jobs-db:       { enabled: true, command: ["python","-um","cheese_database.jobs_app"],         port: 8001 }
  jobs-exec:     { enabled: true, command: ["python","-um","cheese_database.jobs_executor"]                }
  download-exec: { enabled: true, command: ["python","-um","cheese_database.download_executor"]            }

databases:
  test:
    path: /data/on-prem/databases/test_db
    delimiter: ","
    indexType: in_memory
    transformer: morgan_tanimoto

image:
  source: local              # local | acr
```

`databases:` is the values-driven hook for the recurring "add a real database" routine — bumping that map and `helm upgrade` is the established path; the actual data files land on the PVC out-of-band.

## Install order

1. `kind` cluster + ingress controller
2. Namespace + PVC + (optional) ACR pull secret
3. `cheese-database` (data plane up first; orchestrator polls it)
4. `cheese-synthongpt` (optional)
5. `cheese-orchestrator`
6. `cheese-search-ui`
