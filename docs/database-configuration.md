# Database configuration

How the CHEESE engine discovers and loads indexed databases, and what
`cheese download-dbs` writes on your behalf. Read this if a database doesn't
show up, the DB container crash-loops on startup, or search returns garbled
SMILES/IDs.

> TL;DR — for the engine to recognize a database, **two** things must be true:
> 1. the database **folder** contains the exact set of index files the engine
>    expects for its type, and
> 2. the engine config (`cheese_config_file.yaml`) has **three** parallel,
>    same-keyed entries for it: `OUTPUT_DIRECTORIES`, `INDEX_TYPES`, `DELIMITERS`.
>
> `cheese download-dbs` writes all three automatically (inferring the latter two
> from the downloaded folder). The rest of this doc is what it's doing and how to
> fix it by hand if the inference is wrong.
>
> You rarely need to do that by hand: **`cheese start` runs a preflight that
> validates and auto-heals the config before any container starts**, and
> **`cheese doctor`** diagnoses a stack that's already misbehaving and prints the
> fix. See §5.

---

## 0. Getting the databases

Databases are downloaded from a private AWS S3 bucket — the same bucket the
hosted CHEESE service reads, so you get byte-identical data. Access is by IAM
only: the bucket is private, blocks public access, and requires TLS.

**Authentication is one access key, for everything.** DeepMedChem issues you a
single AWS access key that pulls the container images *and* downloads the
databases. There is no separate database password. The key carries no
permissions of its own — its only right is to assume a read-only role, so the
worst case if it leaks is that someone downloads data you are already licensed
for. (Older installs used an SFTP server with `DB_SERVER` and
`CHEESE_DB_PASSWORD`; that server is retired and those settings are ignored.)

```bash
cheese aws-auth                        # paste the key once; it is verified before being stored
cheese aws-auth --check                # re-test it later
cheese configure-dbs                   # see what's available, with sizes; choose what you want
cheese download-dbs --dest /srv/cheese-databases
```

`aws-auth` stores the key in `~/.config/cheese/aws-credentials.conf`, mode
`0600` — deliberately *not* in `cheese-env-file.conf`, which is world-readable
because docker compose reads it. Use `--file` to put it somewhere else; the
location is recorded so later commands still find it.

**Requirements:** the AWS CLI v2 (`bash install/install-aws-cli.sh`) and
outbound HTTPS to `us-east-1`. Nothing needs to be open inbound.

### Choosing what to download

A CHEESE licence entitles you to **every** database — there is no per-database
licensing — so the only question is which ones you have room for. They are
large: the smallest is a few GB, the largest over 1.4 TB, and the full catalog
is several terabytes.

`cheese configure-dbs` prints each database with its size and writes your
choices to `~/.config/cheese/databases.conf`. `download-dbs` then fetches only
the ones flagged `yes`, and refuses to run at all without a selection — there is
no implicit "download everything" (use `--all` if that is genuinely what you
want). It also checks free disk space against the selection before starting, and
warns if you have picked two builds of the same database (for example the 2024
and 2026 mcule indexes, which share one CHEESE name).

The list of databases comes from `config/databases.catalog`, shipped with these
scripts, because the read-only role can read the database folders but cannot list
the bucket root. `configure-dbs` checks every catalogued entry against the bucket
and marks anything unavailable, so a stale catalog is visible rather than silent.

### Transfers are resumable

`download-dbs` uses `aws s3 sync`, which is incremental: files already present
with a matching size are skipped. An interrupted download resumes where it left
off — re-run the same command. A 1 TB database over a slow link takes many hours,
which is why the credentials are configured to refresh themselves mid-transfer
rather than expiring after an hour.

Use `--dry-run` to see exactly what would be transferred without moving any bytes
or touching any config.

### Kubernetes installs

The above is the docker-compose path. In a Helm-chart install nothing reads
`~/.config/cheese/`, so use `cheese aws-auth --target k8s` to store the key as a
Kubernetes Secret instead (or `--target print` to emit the manifest for
SealedSecrets / Vault / a GitOps repo). Getting the data onto the chart's data
volume is a separate step from storing the credential — see the k8s README.

---

## 1. The three config maps

The engine reads its config at **import time**
(`cheese-database/cheese_database/indices/database.py`). It builds three
dictionaries, all keyed by the **database name**:

```yaml
OUTPUT_DIRECTORIES:
  mcule_purchasable_in_stock_240717_clustered: '/mnt/DATA/cheese-databases/mcule_purchasable_in_stock_240717_clustered'
INDEX_TYPES:
  mcule_purchasable_in_stock_240717_clustered: "clustered"      # clustered | in_memory
DELIMITERS:
  mcule_purchasable_in_stock_240717_clustered: ","              # column separator
```

The startup loop iterates over `OUTPUT_DIRECTORIES` and immediately indexes
`INDEX_TYPES[db_name]` and `DELIMITERS[db_name]`. **A database listed in
`OUTPUT_DIRECTORIES` but missing from either of the other two maps raises
`KeyError` at import — the DB container crash-loops and never serves.** This is
the single most common misconfiguration.

The keys must be **identical across all three maps**. The key is also the
human-facing database name (it appears in result IDs, e.g.
`mcule_... : <id>`), so pick something readable; `download-dbs` uses the folder
name on the server.

### `OUTPUT_DIRECTORIES` — where the files are

The value is a **host absolute path** to the database folder, e.g.
`/mnt/DATA/cheese-databases/mcule_...`.

Why a *host* path works inside the container: the DB services mount the host
root at `/data` (`docker-compose.yml`: `- /:/data`), and the engine resolves
every path as `${DATA_ROOT}/<path>` with `DATA_ROOT=/data`. So the host path
`/mnt/DATA/cheese-databases/mcule_...` is read at
`/data/mnt/DATA/cheese-databases/mcule_...` inside the container — the same
files. `download-dbs` writes `--dest/<db>` directly, so this lines up
automatically; if you register a DB by hand, give it the **host** path.

### `INDEX_TYPES` — `clustered` or `in_memory`

Selects both the on-disk layout the engine expects (see §2) and the search
code path. The two valid values:

| value       | what it is                                                        |
|-------------|-------------------------------------------------------------------|
| `clustered` | large catalog stored as clustered SMILES shards (Enamine, ZINC, mcule, …) |
| `in_memory` | smaller catalog loaded fully into memory (DzDB)                   |

A wrong value here means the engine looks for the wrong files and raises
`ValueError: Directory structure not correct …` at startup.

### `DELIMITERS` — how a result line is split

When returning hits, the engine splits each stored line on this delimiter:
field 0 → SMILES, field 1 → ID. So the delimiter must match the actual file
format. Valid values are a tab or a comma:

```yaml
DELIMITERS:
  some_tab_db:   "\t"     # MUST be double-quoted — see the warning below
  some_comma_db: ","
```

> ⚠️ **Quote the tab as `"\t"` (double quotes).** YAML only interprets the
> escape inside *double* quotes; single-quoted `'\t'` is the literal two
> characters backslash-t and will silently break line parsing. Comma is
> unambiguous either way.

A wrong delimiter doesn't crash the engine — it **silently corrupts results**
(SMILES strings include trailing columns, IDs come out wrong). Most CHEESE
catalogs are comma-delimited; Enamine-style exports are tab-delimited.

---

## 2. Required folder structure

The engine validates the folder layout per `INDEX_TYPES` value and refuses to
start if anything is missing (it prints `Missing file/directory: …`).

**`clustered`** — needs all of:

```
<db>/
├── smiles_clusters/            # gzipped per-cluster SMILES shards, per model
├── clusters/
├── centroid_index/
├── numlines.txt                # total molecule count
├── espsim_cluster_sizes.txt
├── shapesim_cluster_sizes.txt
└── tanimoto_cluster_sizes.txt
```

**`in_memory`** — needs all of:

```
<db>/
├── embeddings/
├── fingerprints/
├── indexes/
├── numlines.txt
├── database.txt                # the molecules, loaded via DzDB
└── byteoffsets.txt
```

These files are produced by the indexing pipeline and shipped on the database
server as-is, so a **complete** download satisfies the structure check. A
partial/interrupted download can leave the folder missing files — re-run
`cheese download-dbs` (it resumes and fills in what's missing).

---

## 3. What `cheese download-dbs` automates

After each database finishes downloading, `download-dbs` registers it into
`cheese_config_file.yaml` so you don't hand-edit YAML:

- **`OUTPUT_DIRECTORIES`** — set to the download destination path.
- **`INDEX_TYPES`** — inferred from the folder structure: `smiles_clusters/` +
  `clusters/` → `clustered`; `embeddings/` + `fingerprints/` → `in_memory`.
- **`DELIMITERS`** — inferred by peeking at one real data line (a cluster
  `.txt.gz` for clustered DBs, `database.txt` for in_memory): a tab → `"\t"`,
  otherwise `","`. Defaults to comma when it can't tell.

The editor is **section-scoped**: it updates an existing key in place under the
right section, or inserts a new one after the section header — so re-running is
idempotent and the same DB name across three sections is never confused.

This same inference + repair logic lives in `scripts/_engine-config` and is
shared with the start-time preflight (`cheese preflight-config`), so a DB
registered at download time always passes the check at start time — the two
can't drift apart.

### When inference fails

`download-dbs` prints a loud `!` warning rather than writing a guess when it
can't determine a value — **act on these before restarting the stack**:

- *Could not infer `INDEX_TYPES`* — the folder didn't match either known layout
  (incomplete download, or a new layout). Set it by hand; the engine won't
  start otherwise.
- *Could not detect the column delimiter … defaulted to `,`* — verify the file
  is actually comma-delimited; if it's tab-delimited, change the entry to
  `"\t"`, or returned SMILES/IDs will be wrong.

---

## 4. Applying changes

The config is read **once at import**, so any edit (auto or manual) requires a
restart:

```sh
cheese stop && cheese start
```

---

## 5. Troubleshooting

**Start here:** `cheese doctor` checks the engine config *and* every `cheese-*`
container in one shot, and for any crash-looping/unhealthy one it maps the real
log line to a cause and the exact fix command. `cheese doctor --fix` also
auto-heals the config problems it can infer. To validate/heal the config without
touching containers, run `cheese preflight-config` (this is what `cheese start`
runs automatically before bringing anything up, so a config drift is fixed — or
reported with an actionable message — instead of becoming a silent crash-loop).

| symptom | likely cause |
|---|---|
| DB container crash-loops immediately on start | a DB is in `OUTPUT_DIRECTORIES` but missing from `INDEX_TYPES` or `DELIMITERS` (KeyError), or the three maps' keys don't match |
| `Directory structure not correct for … database` | wrong `INDEX_TYPES`, or an incomplete download (missing index files — re-run `download-dbs`) |
| `Missing file/directory: …/numlines.txt` (etc.) | incomplete download; re-run `download-dbs` to fill in the gaps |
| search returns malformed SMILES or wrong IDs | wrong `DELIMITERS` value (tab vs comma); fix and restart |
| database simply doesn't appear | no `OUTPUT_DIRECTORIES` entry, or the stack wasn't restarted after editing the config |

---

*Source of truth: `cheese-database/cheese_database/indices/database.py`
(config load + structure checks), `cheese-on-prem/scripts/_engine-config`
(validation + inference + repair, shared by `download-dbs`, `preflight-config`
and `doctor`). If those change, update this doc.*
