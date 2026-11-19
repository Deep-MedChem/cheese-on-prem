# CHEESE V2 — offline install from a bundle

CHEESE V2 is the search-only stack (backend API + UI) that runs entirely from
one offline bundle: images, signed database releases, models and the `cheese`
CLI itself. The target host needs **no network access, no registry, no cloud
credentials and no classic CHEESE install**. The classic `cheese` commands are
unchanged; V2 lives under `cheese v2 ...`.

| | |
|---|---|
| UI | `http://127.0.0.1:18780/` |
| Installed editor revision and file hashes | `http://127.0.0.1:18780/ketcher/build-info.json` |
| API | `http://127.0.0.1:18781/` (`/health/live`, `/health/ready`, `/api/v2/docs`) |
| Host requirements | Linux, bash, coreutils, Docker Engine with the compose v2 plugin |

---

## 1. Build the bundle (connected build host)

Build the production Classic search interface from the on-prem branch of `cheese-search-ui`.
Its site-local gateway sends searches to V2. On the build host, set `ui_repo` to that checkout:

```bash
docker build -f "$ui_repo/Dockerfile.cheese-classic-onprem" \
  --build-arg "SOURCE_REVISION=$(git -C "$ui_repo" rev-parse HEAD)" \
  -t cheese-classic:v2-onprem "$ui_repo"
```

The bundle also needs the V2 backend image and a payload directory:

```
payload/
  release-public-key.txt                              one base64 DER Ed25519 public key
  releases/<database_id>/<release_id>/manifest.json   + manifest.sig + the release files
  models/manifest.json                                + the model files
```

Build the backend with `dmc-platform-backend/Dockerfile.onprem`. It exercises a
native substructure search as the service user against a read-only partition.
Older runtimes can pass readiness yet reject more complex VAST conditions when
RDKit opens a native partition. Use the corrected synthon-core runtime or the
digest-pinned wheel overlay documented in that Dockerfile. Keep signed releases
mounted read-only.

```bash
v2/build-offline-bundle \
  --backend-image <backend image ref> \
  --ui-image      cheese-classic:v2-onprem \
  --payload       /path/to/payload \
  --output        /path/to/cheese-v2-bundle \
  [--sdk-wheelhouse /path/to/sdk-wheelhouse] [--bundle-version pilot-1] [--archive] [--hardlink]
```

The last line printed is the trust anchor, also written to `<output>.digest`:

```
BUNDLE_DIGEST=sha256:<64 hex>
```

**Send that digest to the operator over a different channel than the bundle**
(e.g. a ticket or signed e-mail, while the bundle travels on a disk). It is the
only thing that makes the bundle authentic rather than merely intact.

`--archive` additionally writes `<output>.tar` (+ `.tar.sha256`) for transfer.
`--hardlink` links the payload instead of copying it (same filesystem only).
Each database must have exactly one release; every release must be signed.
`SOURCE_DATE_EPOCH` pins the bundle creation time (used by the downgrade check).

## 2. Trust bootstrap (target host, before running anything from the bundle)

Check the bundle with the host's own tools first, so no bundle code runs
until it is known to be the one the producer built:

```bash
tar -xf cheese-v2-bundle.tar          # if it arrived as an archive
cd cheese-v2-bundle
echo "<64 hex>  SHA256SUMS" | sha256sum -c -                         # the anchor
grep -E '  (install\.sh|cli/.*)$' SHA256SUMS | sha256sum -c --quiet -  # the installer code
```

The installer then re-verifies **every** file before it loads or copies anything.

## 3. Install

```bash
./install.sh --trusted-digest sha256:<64 hex>
```

- Installs into `~/.local/share/cheese-v2` by default. Use `--prefix /opt/cheese-v2`
  (or `CHEESE_V2_PREFIX`) to choose another location; a throwaway `HOME=$(mktemp -d)`
  works too. Nothing is written outside the prefix (no `~/.bashrc`, no `~/.config/cheese`).
- `--link-data` hard-links releases/models from the bundle instead of copying them
  (same filesystem; the bundle directory must then stay unmodified).
- Re-running with the same bundle is a no-op.

The CLI is installed at `<prefix>/bin/cheese` (the full CLI from the bundle):

```bash
export PATH="$HOME/.local/share/cheese-v2/bin:$PATH"   # optional
cheese v2 start      # starts the stack, waits until healthy and reachable from the host
cheese v2 status     # bundle, releases, container health, API readiness (--json available)
cheese v2 logs backend --tail 100
cheese v2 stop       # removes this stack's containers/networks; data, volumes and images stay
```

`start` returns once all containers are healthy and both ports answer on the
host, and the backend reports that its mounted libraries are ready for searches. Use
`--timeout SEC` to allow longer warmup on a slower host. A running update that fails
this check restores the previous bundle.

### Python SDK (optional)

If the bundle includes the SDK wheelhouse:

```bash
cheese v2 sdk-install --venv ~/cheese-sdk [--python python3.11]
~/cheese-sdk/bin/python -c 'import deepmedchem as dmc; print(dmc.Client(api_url="http://127.0.0.1:18781", on_prem=True).catalog())'
```

It installs with `--no-index --require-hashes` from the bundled wheels only.

## 4. Update

```bash
cheese v2 verify --bundle /path/to/new-bundle --trusted-digest sha256:<new digest>   # optional dry run
cheese v2 update --bundle /path/to/new-bundle --trusted-digest sha256:<new digest>
```

`update` uses the **already installed** CLI to verify the new bundle, then:

1. refuses a bundle format this CLI does not understand (run the new bundle's
   `install.sh --prefix <prefix>` after the trust bootstrap instead);
2. refuses a different release signing key unless you confirm the rotation with
   `--accept-release-key sha256:<key digest>`;
3. refuses a bundle older than the installed one unless `--allow-downgrade`;
4. refuses a `<database_id>/<release_id>` that is already installed with
   different content (release IDs are immutable);
5. loads the images (skipped if already present), checks the release
   signatures inside the new backend image with `--network none`, stages only
   releases/models not already present, then switches `current` atomically
   (the old bundle stays as `previous`);
6. if the stack was running, restarts it on the new bundle and, if it does not
   become healthy, **rolls back** to the previous bundle automatically.

Releases and models are content-addressed and shared between bundles; old ones
stay under `<prefix>/data` until you delete them.

## 5. Runtime and network model

One compose project per prefix, `cheese-v2-<8 hex>`; every container, network
and volume carries that project label, so V2 never touches the classic stack
or anything else on the host.

| service | image | networks | notes |
|---|---|---|---|
| `backend` | bundle backend | `internal` | listens 8000; `/data` (releases + models) mounted read-only |
| `ui` | bundle UI | `internal` | listens 3000; `PLATFORM_API_URL=http://backend:8000` |
| `edge` | bundle backend (stdlib Python forwarder) | `internal`, `hostonly` | publishes `127.0.0.1:18780 → ui:3000`, `127.0.0.1:18781 → backend:8000` |

- `internal` is a Docker `internal: true` network: no route off the host, so
  backend and UI have **no egress at all**. Docker cannot publish ports from
  such a network, which is why the tiny `edge` forwarder exists.
- `hostonly` is a bridge with IP masquerading disabled, so even `edge` cannot
  reach the internet; it only carries the loopback-published ports.
- Images run with `pull_policy: never`, all capabilities dropped and
  `no-new-privileges`.

Backend environment (fixed; operator files cannot override it):

```
ENVIRONMENT=production
ONPREM_SEARCH_ONLY=true
LOCAL_LIBRARY_MANIFESTS_JSON={"<database_id>": "/data/releases/<database_id>/<release_id>/manifest.json", ...}
MODEL_ROOT=/data/models/<model manifest sha256>
MODEL_MANIFEST_SHA256=<sha256 of models/manifest.json>
RELEASE_PUBLIC_KEY_B64=<release-public-key.txt>
```

UI environment: `ONPREM_SEARCH_ONLY=true VITE_ONPREM_SEARCH_ONLY=true PLATFORM_API_URL=http://backend:8000 PORT=3000`.
No API keys or `AUTH_DISABLED` are set: the search-only runtime is account-free.

Operator settings in `<prefix>/config/` (applied on the next `cheese v2 start`):

| file | purpose |
|---|---|
| `v2.conf` | `CHEESE_V2_BIND` (default `127.0.0.1`), `CHEESE_V2_UI_PORT`, `CHEESE_V2_API_PORT` |
| `backend.env`, `ui.env` | extra container environment (cannot override the contract above) |
| `secrets.env` | empty by default, mode 0600; passed to both containers |

## 6. Trust model

| What | Protected by |
|---|---|
| The whole bundle | `SHA256SUMS` lists every file; its sha256 (`BUNDLE_DIGEST`) is the **external trust anchor** delivered out of band. The bundle itself is not signed. Files not listed, symlinks and unsafe paths are rejected. |
| Database releases | Ed25519-signed (`manifest.sig`). Checked by the CLI inside the new backend image before cutover, and again by the backend at every start, together with every file hash the manifest declares. |
| The release public key | Trusted through the anchor; its sha256 is **pinned** at first install. A different key on update needs `--accept-release-key`. |
| Models | Not signed: `MODEL_MANIFEST_SHA256` (from the anchored bundle) pins `models/manifest.json`, which pins every model file; the backend verifies them at start. |
| Images | `docker load` result must have the exact image IDs (content digests) recorded in the anchored `bundle.env`; they are then tagged `cheese-v2/{backend,ui}:<digest12>`. |
| The CLI | Inside the anchored bundle; on install, check it with the trust bootstrap above. On update, the already-installed CLI verifies the new bundle before any of its code runs. |

`--allow-untrusted` skips the anchor (integrity is still checked, authenticity
is not). It exists for tests only.

## 7. Layout and removal

```
<prefix>/
  bin/cheese                  -> current/cli/scripts/cheese
  current, previous           -> bundles/<digest12>
  bundles/<digest12>/         bundle.env, releases.tsv, SHA256SUMS, release-public-key.txt, cli/, sdk/
  data/releases/<db>/<rel>/   signed releases (read-only mount)
  data/models/<sha256>/       models
  config/                     v2.conf, backend.env, ui.env, secrets.env
  state/                      installed.env, runtime.env
```

To remove V2 completely: `cheese v2 stop`, then
`docker volume rm <project>_runtime <project>_cache`,
`docker rmi cheese-v2/backend:<digest12> cheese-v2/ui:<digest12>` (project and
digest are shown by `cheese v2 status`), and delete the prefix directory.

## 8. Tests

```bash
python3 -m unittest discover -s tests/v2 -v        # fake docker; no containers started
CHEESE_V2_IT_BASE_IMAGE=<local backend image> \
  python3 -m unittest tests/v2/test_docker_integration.py -v   # real Docker, stand-in images
```

The integration test builds stand-in images on top of a local backend image,
signs real releases, installs into a temporary HOME and checks loopback
access, UI→backend wiring, the absence of internet egress, read-only data and
the in-image signature check. It removes everything it created.
