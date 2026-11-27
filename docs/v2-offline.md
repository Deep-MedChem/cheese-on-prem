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

Or take the image CI already built: cheese-search-ui publishes it to
`815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/cheese/cheese-search-ui`
(`v2-prod-<sha>` from main, `v2-dev-<sha>` from develop). Pass it pinned by digest;
the producer pulls it, so log Docker in to ECR first:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS \
  --password-stdin 815935788477.dkr.ecr.us-east-1.amazonaws.com
--ui-image 815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/cheese/cheese-search-ui@sha256:<hex>
```

`bundle.json` records the UI's registry `digest` and its `revision`
(`org.opencontainers.image.revision`); both are `null` for a local build that was never pushed.

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

### Support bundle

When something goes wrong, `cheese v2 support-bundle` packs what support needs into one file. It
sends nothing: you read the file and attach it to the ticket or email yourself.

```bash
cheese v2 support-bundle                       # ./cheese-support-<UTC time>.tar.gz, logs of the last 24h
cheese v2 support-bundle --since 3d --output /tmp/cheese-support.tar.gz
```

| File | Content |
| --- | --- |
| `install.txt` | Installed bundle and digest, releases, service health, liveness and readiness |
| `host.txt` | Kernel, CPUs, memory, load, free disk under the prefix, Docker versions |
| `containers.txt` | State, restarts, out-of-memory kills and current CPU and memory of each container |
| `requests.txt` | Requests in the window by path and status, with mean and longest duration |
| `errors.log` | Warnings, errors and requests answered with 4xx or 5xx, with their request IDs |
| `backend-events.log` | Backend events in the window (at most 20,000), health probes left out |

The file does not carry what was searched for. Backend log lines are not copied: each structured
line is rebuilt from its event name and a fixed list of fields (database, operation, counts,
durations, method, path, status, error code, request ID), a value is kept only when it is a single
plain token, and paths lose their query string. Query structures, request bodies, API keys, user
names, free-text messages and tracebacks are left out, as is all UI and edge output; `README.txt`
in the file says how many lines were left out. The command works with the stack stopped, and
without Docker access it still writes the install and host files.

### Python SDK (optional)

If the bundle includes the SDK wheelhouse:

```bash
cheese v2 sdk-install --venv ~/cheese-sdk --python python3.11
~/cheese-sdk/bin/python -c 'import deepmedchem as dmc; print(dmc.Client(api_url="http://127.0.0.1:18781", on_prem=True).catalog())'
```

It installs with `--no-index --require-hashes` from the bundled wheels only.

#### Shared Jupyter server

Starting with the `onprem2` SDK wheel, one kernel can supply the site for every notebook user. On the notebook server, use a dedicated Linux x86-64 CPython 3.11 environment with pip and ipykernel installed from your internal distribution. Choose a Jupyter prefix whose `share/jupyter/kernels` directory is visible to the server. From the extracted offline bundle run:

```bash
./cli/v2/install-notebook-kernel ./sdk/wheelhouse /opt/cheese-kernel/bin/python \
  /opt/jupyter https://cheese.your-pharma-company.com
```

Replace the URL with your internal HTTPS origin. The installer verifies the wheelhouse, installs the pinned SDK dependencies in the chosen interpreter and registers **CHEESE (on-prem)** in that prefix. Rerun with the new wheelhouse to update this kernel. Users select it and run:

```python
from deepmedchem import Client

with Client(on_prem=True) as cheese:
    print(cheese.catalog())
```

The kernel sets `DEEPMEDCHEM_ON_PREM_URL`. Plain `Client()`, `AsyncClient()` and SDK search helpers use that site too. Passing `on_prem=True` also makes a notebook fail early if it is opened in a kernel without a configured site. Users can read the local API docs at `/api/v2/docs` on their deployment hostname.

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

### Download the bundle over the network (optional)

A site that allows one outbound connection can download the bundle instead of
receiving it on a disk. `fetch` is the only command that uses the network; it
needs `curl` on the host and changes nothing in the installation.

```bash
cheese v2 fetch --from sftp://transfer.example.com/cheese/cheese-v2-bundle \
  --output /srv/cheese-media/cheese-v2-bundle \
  --trusted-digest sha256:<new digest> [--curl-config /etc/cheese/transfer.curl]
cheese v2 update --bundle /srv/cheese-media/cheese-v2-bundle --trusted-digest sha256:<new digest>
```

- `--from` is the address of the bundle **directory** as the producer published
  it: `https://`, `sftp://` or `ftps://` (also `http://`, `ftp://` and
  `file://`; the first two are not encrypted and print a warning).
- The digest still arrives over a separate channel. `fetch` downloads
  `SHA256SUMS` first and stops if it is not the trusted one, so nothing else is
  taken from a wrong or altered source. Each file is then checked against its
  entry before it is kept.
- Releases and models that this installation already has are taken from it, not
  downloaded: a bundle that adds or replaces one database transfers that
  database, the images and the small files.
- An interrupted download continues where it stopped when the same command runs
  again (`<output>.partial` holds the files received so far).
- Credentials go into a curl configuration file readable only by the operator,
  never into the URL (`fetch` refuses a password there):

  ```
  # /etc/cheese/transfer.curl (mode 0600)
  user = "jnj-cheese"
  key = "/home/operator/.ssh/cheese_transfer"
  pubkey = "/home/operator/.ssh/cheese_transfer.pub"
  # or for a password:  user = "jnj-cheese:<password>"
  # proxy = "http://proxy.example.com:3128"
  # cacert = "/etc/ssl/certs/internal-ca.pem"
  ```

- For `sftp://`, curl checks the server's host key against the operator's
  `~/.ssh/known_hosts`; add it once, after comparing it with the key the
  producer sent: `ssh-keyscan -p <port> <host> >> ~/.ssh/known_hosts`.
- `--jobs N` sets how many files are downloaded at once (default 4).
- The very first bundle has no installed CLI to fetch it. Either bring that one
  on a disk, or run the single script the producer sends:
  `bash cheese-v2 fetch --from ... --output ... --trusted-digest ...`.

On the producer side, publish the bundle directory unchanged (not the `.tar`),
for example `sftp> put -r cheese-v2-bundle` or `aws s3 sync cheese-v2-bundle
s3://<bucket>/cheese-v2-bundle` behind an HTTPS endpoint. The server needs no
directory listing: `SHA256SUMS` names every file.

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
| `v2.conf` | `CHEESE_V2_BIND` (default `127.0.0.1`), `CHEESE_V2_UI_PORT`, `CHEESE_V2_API_PORT`<br>`CHEESE_V2_UI_IMAGE_OVERRIDE`: internal preview hosts only, never customer sites. A UI image pinned by digest (`<repository>@sha256:<hex>`, pulled beforehand) that replaces the bundle's UI; backend, data and edge stay the bundle's. |
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
