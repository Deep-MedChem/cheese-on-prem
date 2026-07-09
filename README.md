# CHEESE platform on-premises 

![cheese.png](assets/cheese.png)

Full CHEESE platform on-premises version.

### Requirements

- A physical or virtual machine with Ubuntu 24.
- git
- Docker; the unix user must be a member of the `docker` group (check by running `docker ps`).

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

3. Contact us to provide you with registry credentials (`CHEESE_AWS_ACCESS_KEY_ID` + `CHEESE_AWS_SECRET_ACCESS_KEY`) to be able to download CHEESE docker images. (The legacy `CHEESE_PASSWORD` no longer works — the old Azure registry has been retired.)

4. Run `cheese update-env` and insert the credentials in the config file

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

Will fetch the list of available databases from the CHEESE SFTP server. 

2. fetches the selected databases and auto-register them in the engine config: 

```bash
cheese download-dbs --dest <folder>
```
For how the engine recognizes a
database (the required folder structure and the `OUTPUT_DIRECTORIES` /
`INDEX_TYPES` / `DELIMITERS` config entries), and how to fix a DB that won't
load, see [docs/database-configuration.md](docs/database-configuration.md).

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

Full guide: [docs/supabase-auth-setup.md](docs/supabase-auth-setup.md).

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

Full guide: [docs/custom-auth-setup.md](docs/custom-auth-setup.md).


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
* Rclone

Automatically pulled by `docker` upon installation.
