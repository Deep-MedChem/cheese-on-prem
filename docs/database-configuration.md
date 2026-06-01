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

| symptom | likely cause |
|---|---|
| DB container crash-loops immediately on start | a DB is in `OUTPUT_DIRECTORIES` but missing from `INDEX_TYPES` or `DELIMITERS` (KeyError), or the three maps' keys don't match |
| `Directory structure not correct for … database` | wrong `INDEX_TYPES`, or an incomplete download (missing index files — re-run `download-dbs`) |
| `Missing file/directory: …/numlines.txt` (etc.) | incomplete download; re-run `download-dbs` to fill in the gaps |
| search returns malformed SMILES or wrong IDs | wrong `DELIMITERS` value (tab vs comma); fix and restart |
| database simply doesn't appear | no `OUTPUT_DIRECTORIES` entry, or the stack wasn't restarted after editing the config |

---

*Source of truth: `cheese-database/cheese_database/indices/database.py`
(config load + structure checks) and `cheese-on-prem/scripts/download-dbs`
(auto-registration). If those change, update this doc.*
