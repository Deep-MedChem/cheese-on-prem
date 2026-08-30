# CHEESE on-premises — Docker Compose install

<kbd>🖥️ single host</kbd> <kbd>🐳 docker compose</kbd> <kbd>⭐ recommended</kbd>

![cheese.png](../assets/cheese.png)

The full CHEESE platform on one machine, managed by `docker compose` and driven
by the `cheese` command-line tool. This is the standard install — if you are not
deploying onto an existing Kubernetes cluster, this is the one you want.

> **Read [the top-level README](../README.md) first** for the requirements common
> to every install type: the access key, the licence, network egress, and how much
> disk the databases need. This page covers only what is specific to the Compose
> install.
>
> Paths and commands below are relative to the **repository root**, which is where
> the Compose install lives.

### Requirements

- A physical or virtual machine with Ubuntu 24.
- git
- Docker; the unix user must be a member of the `docker` group (check by running `docker ps`).
- The **AWS CLI v2** (`aws --version`). CHEESE uses it to authenticate to the
  image registry and to download the indexed databases. Install it with
  `bash install/install-aws-cli.sh` if you don't have it — use AWS's own
  installer rather than `apt install awscli`, which on some Ubuntu releases is
  still v1 and cannot refresh credentials during a long database transfer.

## Installing CHEESE

### 1. CHEESE CLI

You can install CHEESE on your instance using the following steps :

1. Clone this repository 

```bash
git clone git@github.com:Deep-MedChem/cheese-on-prem.git
```

2. Install CHEESE CLI: 

```bash
bash install-cheese.sh
``` 
in the repo's directory. Follow the prompts. Then re-log in to the shell (or run `source ~/.bashrc`) and check if the installation completed by running `cheese`

3. Contact us for your **AWS access key** (an access key ID and a secret). One
   key covers everything: pulling the CHEESE images and downloading the
   databases. There is no separate database password. (The legacy
   `CHEESE_PASSWORD` and the `DB_SERVER`/`CHEESE_DB_PASSWORD` SFTP settings are
   obsolete and no longer work.)

4. Run `cheese aws-auth` and paste the key when prompted. It checks the key
   against AWS before storing it, so you find out immediately whether it works,
   and it writes it to a file only your user can read. You only do this once —
   re-run it to rotate a key, or `cheese aws-auth --check` to re-test one.

5. Run `cheese update-images` to be able to download the docker images. _This step will take a while!_

6. After `cheese-database` image is successfully pulled, run `cheese generate-license-key` to generate your license key.

7. Send us the key so that we can generate your license file.

8. Once we send you the JSON license file, run `cheese update-license` and paste its contents there.

9. You can now use CHEESE on-prem version. Start the platform by running `cheese start`
> This starts a docker network of about 10 containers. The startup takes a few minutes.

### 2. CHEESE databases

By default, CHEESE comes with a small test database which can be used to test the general workflow.

Database download happens in two steps:

1. `cheese configure-dbs`

Will list the databases available to you, with their sizes, so you can choose
what to download. 

2. fetches the selected databases and auto-register them in the engine config: 

```bash
cheese download-dbs --dest <folder>
```
For how the engine recognizes a
database (the required folder structure and the `OUTPUT_DIRECTORIES` /
`INDEX_TYPES` / `DELIMITERS` config entries), and how to fix a DB that won't
load, see [docs/database-configuration.md](database-configuration.md).

### Authentication & user accounts (optional)

By default, CHEESE on-prem runs with no authentication: anyone who can reach the
UI gets the full product, and everyone shares one workspace (searches, downloads
and history are common to all users). Two independent options change that:

#### Option A — per-user accounts with private spaces (self-hosted Supabase)

Every user signs in with their own email/password and gets a **private space**
(their searches, downloads and history are visible only to them), while all
accounts keep full access to the product. This runs a slim self-hosted Supabase
next to CHEESE — it needs nothing from your infrastructure except Docker.

```bash
cheese setup-supabase        # generates secrets, pulls + starts Supabase, wires the config
cheese update-images         # pulls the auth-enabled UI variant (<channel>-auth)
cheese stop && cheese start
```

> The login UI is compiled into the image at build time, so accounts use a
> dedicated **auth variant** of the UI image (`<channel>-auth`, e.g.
> `develop-auth`). `cheese setup-supabase` selects it automatically via
> `CHEESE_UI_IMAGE_TAG`; the rest of the stack stays on the regular channel tag.

Full guide: [docs/supabase-auth-setup.md](supabase-auth-setup.md).

#### Option B — sign-in via your corporate IdP (SSO perimeter)

An nginx + oauth2-proxy perimeter in front of CHEESE forces every visitor to
sign in through your own identity provider (Azure/Entra ID, Okta, or any OIDC
IdP) before anything reaches the stack. Configure with `cheese configure-oauth2`
and `cheese configure-nginx`, then set `NGINX=true` and restart.

> Note: SSO controls **who gets in**, but behind it all users still share one
> common workspace — it does not create per-user private spaces. Combine it with
> Option A if you want both corporate sign-in and per-user isolation (with the
> perimeter on, Supabase is served through nginx at `https://<host>/supabase`
> and is never exposed on its own port).

Full guide: [docs/custom-auth-setup.md](custom-auth-setup.md).


## Housekeeping

### Updating CHEESE

Currently, there is no support for automatic updates (COMING SOON!). 
When we notify you that the update is necessary, please run:
```bash
cheese update  
```
It pulls the latest scripts from this repo and writes them as well as the images from the container repository.

### Troubleshooting

```bash
cheese doctor
```
Identifies unhealthy containers and runs basic diagnostics. 

## Uninstall

```bash
cheese uninstall
```

Following the prompts, you chose to delete all or either of:
- cheese environment
- cheese images
- cheese scripts

## What's under the hood

CHEESE stack is managed by `docker compose` - you can use common `compose` commands to diagnose and troubleshoot.
The stack runs as the compose project `cheese`, so target it with `-p cheese`.
Service names are `db`, `api`, `ui`, `jobs-db`, `jobs-exec`, `download-exec`, `file-server`, `inference`, `alignment`, `ketcher`.
Examples:

* Status — every CHEESE container and whether it's healthy:
```bash
docker compose -p cheese ps
```

* Inspecting — follow a service's logs live, tail the whole stack, or look at one container by name:
```bash
docker compose -p cheese logs -f api        # follow one service
docker compose -p cheese logs --tail 100    # last 100 lines, all services
docker logs cheese-file-server --tail 20    # a single container by name
```

* Restart a single service (e.g. after editing the engine config):
```bash
docker compose -p cheese restart api
```

* Open a shell inside a container to poke around:
```bash
docker compose -p cheese exec db bash
```

* Resource usage (CPU / memory) of the running containers:
```bash
docker stats $(docker compose -p cheese ps -q)
```


### External dependencies

* Nginx
* Oauth2
* AWS CLI v2 (image registry auth + database downloads)

Automatically pulled by `docker` upon installation.
