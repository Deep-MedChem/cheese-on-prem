# CHEESE on-prem — security & least-privilege

The on-prem stack ships **least-privilege by default**, suitable for shared or
HPC hosts. This page explains what the containers are allowed to do, why, and how
to tighten or relax it.

## Summary

| Setting | Default | Notes |
|---|---|---|
| `privileged` | **never** | No container is privileged. |
| Linux capabilities | `cap_drop: ALL` | Only nginx (SSO profile) re-adds `NET_BIND_SERVICE`, `CHOWN`, `SETUID`, `SETGID` to bind 80/443 and drop its workers. |
| Privilege escalation | `no-new-privileges` | Set on every container. |
| User | invoking UID | Containers run as the non-root user that launched the stack, never root. |
| Host filesystem | 3 scoped mounts | No host-root mount. DBs/models **read-only**, `~/.config/cheese` **read-only**, jobs dir read-write. |
| Port binding | `127.0.0.1` | All published ports bind localhost unless you opt out (`BIND_ADDR`) or front the stack with the SSO proxy. |

## Why the pre-2026 defaults looked broad (and why none were required)

Earlier bring-up images shipped with `privileged: true`, a `/:/data` host-root
mount, and `0.0.0.0` port binds. None of these were actually required by CHEESE;
they were single-host convenience defaults that have now been removed.

- **`privileged`** — CHEESE's only host-level touchpoint is reading a handful of
  **world-readable** DMI attributes under `/sys/devices/virtual/dmi/id/` for
  hardware-locked license validation. `/sys` is mounted read-only into every
  container by default and those files need no elevated privileges, so
  `privileged` was never needed. GPU access, where used, goes through the NVIDIA
  container runtime (`gpus: all` / device reservations), not `privileged`.
- **`/:/data:rw`** — The engine resolves data/model/license/config locations from
  **absolute host paths** and internally prefixes them with a `/data` mount root
  (configurable via `DATA_ROOT`). Mounting the whole host root was a shortcut so
  any absolute path would resolve. Mounting each required subtree at the **same**
  `/data/<abs-path>` location resolves identically — with no code change — so only
  three paths are mounted now.
- **`0.0.0.0`** — Docker's default publish behaviour, not a deliberate choice.

## The three mounts

Instead of `- /:/data`, each service that needs host data gets exactly:

| Host path | In-container | Mode | Contents |
|---|---|---|---|
| `${CHEESE_DATA_DIR}` | `/data${CHEESE_DATA_DIR}` | **ro** | Databases + models (read at serve time; written offline by `download-dbs`). |
| `~/.config/cheese` | `/data~/.config/cheese` | **ro** | License file, engine config, nginx certs, generated env. |
| `${JOBS_DATA_PATH}` | `/data${JOBS_DATA_PATH}` | rw | Search-job state + download artifacts — the only writable mount. |

Mounting at the same `/data<abs-path>` location means every absolute path the app
builds still resolves, so this needs no application changes.

### `CHEESE_DATA_DIR`

The host directory holding your downloaded databases and models.
`cheese download-dbs --dest <dir>` records it into `cheese-env-file.conf`
automatically. On a pre-existing install that predates this, `cheese start`
derives it from the common parent of the database paths in
`cheese_config_file.yaml` (`OUTPUT_DIRECTORIES`), ignoring the in-repo test
fixture. Set it explicitly in `cheese-env-file.conf` to override.

> If your databases live under several unrelated roots, point `CHEESE_DATA_DIR`
> at their common parent (still read-only), or add extra read-only mounts to the
> `x-cheese-data-mounts` anchor in `docker-compose.yml`.

## Network exposure

Published ports bind `${BIND_ADDR:-127.0.0.1}`. Internal-only services
(inference, alignment, oauth2-proxy) always bind `127.0.0.1` regardless.

- **Localhost only (default):** reach the UI via an SSH tunnel or a reverse proxy
  you control.
- **Perimeter auth (recommended for multi-user):** `NGINX=true` enables the
  `--profile sso` stack — nginx + oauth2-proxy in front, terminating TLS and
  authenticating against your corporate IdP. In this mode nginx is the **only**
  service that should face the network; leave every other service on
  `127.0.0.1`. Set `NGINX_BIND_ADDR` to the host NIC (default `0.0.0.0`).
- **Direct off-box access without the proxy:** set `BIND_ADDR` to a specific NIC
  (or `0.0.0.0`). Not recommended for shared hosts.

> **Note — SSO authenticates, it does not segregate.** The oauth2-proxy perimeter
> controls *who can sign in*; behind it all users share a single `universal-cheese`
> identity (shared jobs, searches and downloads). Per-user *private* spaces require
> the self-hosted Supabase accounts build (see `docs/supabase-auth-setup.md`).

## Optional: read-only root filesystem

The `x-hardening` anchor in `docker-compose.yml` includes a commented `read_only:
true` + `tmpfs: /tmp` block. The app writes caches under `/tmp`
(`CUPY_CACHE_DIR=/tmp`); after pointing any other HOME-based caches at `/tmp`,
enable it for an immutable root filesystem. Validate in your environment first.

## Verifying the posture

```bash
# No privileged containers, all non-root:
docker inspect $(docker ps -q --filter name=cheese-) \
  --format '{{.Name}}  privileged={{.HostConfig.Privileged}}  user={{.Config.User}}'

# Only the expected host paths are mounted, DB/config read-only:
docker inspect cheese-db \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{if .RW}}rw{{else}}ro{{end}}){{"\n"}}{{end}}'

# Ports bound to localhost (or your chosen BIND_ADDR):
docker ps --format '{{.Names}}\t{{.Ports}}'
```
