# CHEESE platform — on-premises

![cheese.png](assets/cheese.png)

CHEESE (**CH**emical **E**mbeddings **S**earch **E**ngine) run entirely inside
your own infrastructure. Ultra-large chemical space search over billions of
molecules, with no data leaving your network: molecules you search are never
sent anywhere, and the databases you download are yours to keep offline.

This repository contains everything needed to deploy it. Pick the install type
that matches your infrastructure — each is self-contained and has its own guide.

---

## Choose your install

| | Install | Guide | Use it when |
|---|---|---|---|
| <kbd>🐳 compose</kbd> | **Docker Compose on a single host** | **[docs/compose-install.md](docs/compose-install.md)** | The standard install. You have a VM or physical server and want the whole platform running with one command. Start here unless you specifically need Kubernetes. |
| <kbd>☸️ k8s</kbd> | **Kubernetes (Helm chart)** | **[k8s/README.md](k8s/README.md)** | You already run a Kubernetes cluster and want CHEESE deployed into it with your existing storage, ingress and secret management. |

Both install types run the same product images and read the same databases. They
differ only in how the containers are orchestrated.

---

## What you need, whichever install you choose

### <kbd>🔑 credentials</kbd> One AWS access key

DeepMedChem issues you a single AWS access key (an ID starting with `AKIA` and a
secret). That one key does everything: it pulls the container images **and**
downloads the indexed databases. There is no separate database password.

The key carries no permissions of its own — its only right is to assume a
read-only role. So the worst case if it leaks is that someone can download the
images and databases you are already licensed for.

### <kbd>📄 licence</kbd> A licence file

The product images verify a licence file at startup. After your first image pull
you generate a key, send it to us, and we return the licence file. The Compose
guide walks through this; on Kubernetes it is supplied as a Secret.

### <kbd>🌐 network</kbd> Outbound HTTPS to AWS

Both installs need outbound HTTPS to AWS in `us-east-1` — Elastic Container
Registry for the images, S3 for the databases. **No inbound access is required**,
and nothing phones home during normal operation.

### <kbd>💾 disk</kbd> Room for the databases

The databases are the bulk of the footprint, and they are large. A CHEESE licence
entitles you to **all** of them, so the only question is which ones you have room
for. Run `cheese configure-dbs` to see the full list with exact sizes before
committing to a download.

| | Size |
|---|---|
| The whole catalogue (20 databases) | **≈ 8 TB** |
| Largest single database (`10B_Beyond_RO5_chunks`) | ≈ 1.3 TB |
| Smallest single database (`enamine_amino_acids`) | ≈ 625 MB |
| A typical useful starting set (e.g. ZINC15 + MCULE in-stock + MolPort) | ≈ 135 GB |
| Bundled test database | a few MB, ships with this repo |

Downloads are resumable and incremental, so a large database can be fetched over
several sessions. Plan for the sum of what you select plus roughly 10% headroom.

### <kbd>🖥️ compute</kbd> Hardware

Search is CPU- and memory-bound; a GPU is optional and only accelerates the
embedding/indexing of your own custom databases. Sizing depends heavily on which
databases you load and how many concurrent users you expect — contact us and we
will size it with you.

---

## Repository layout

```
install-cheese.sh        Installs the `cheese` CLI (Docker Compose install)
docker-compose.yml       The stack; docker-compose.supabase.yml adds accounts
scripts/                 The `cheese` command and its subcommands
config/                  Config templates + the database catalogue
install/                 Dependency installers and the environment loader
docs/                    Documentation, including the Compose install guide
tests/                   The bundled test database
k8s/                     Kubernetes install: the CHEESE Helm chart, plus
                         local-dev tooling for testing it on kind
assets/                  Images used by the documentation
deprecated/              Retired components, kept for reference only
```

The Docker Compose install lives at the repository root; the Kubernetes install
is self-contained under `k8s/`.

Reference documentation lives in [docs/](docs/) — including
[database-configuration.md](docs/database-configuration.md), which
explains how databases are delivered and how the engine discovers them. That one
is worth reading whichever install type you use, since the database layout and
the engine's config maps are the same in both.

---

## Support

Reach out to the DeepMedChem team for your access key, your licence file, and
help sizing a deployment. If something is broken, `cheese doctor` (Compose)
collects the diagnostics we will ask for.
