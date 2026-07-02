# Per-user accounts for CHEESE on-prem (self-hosted Supabase)

Adds authentication and per-user data isolation to a CHEESE on-prem
deployment: users sign in with email/password, and each account can only
reach its own application data — enforced by Postgres Row-Level Security,
not by the UI. Backing store is a slim self-hosted Supabase (Postgres +
GoTrue + PostgREST) running as a second compose project next to CHEESE.

Setup is one command plus an image pull. Requires Docker only — no corporate
IdP, no SMTP, no cloud services, no outbound connections.


## What gets deployed

Compose project `cheese-supabase` on the shared `cheese-network`:

| Service            | Image                    | Role                                              |
| ------------------ | ------------------------ | ------------------------------------------------- |
| `supabase-db`      | `supabase/postgres`      | Users + per-user tables + RLS policies            |
| `supabase-auth`    | `supabase/gotrue`        | Email/password signup & login, issues JWTs        |
| `supabase-rest`    | `postgrest/postgrest`    | REST API the browser reads/writes its rows through |
| `supabase-meta`    | `supabase/postgres-meta` | Backs Studio                                      |
| `supabase-studio`  | `supabase/studio`        | Admin dashboard (manage users), behind basic auth |
| `supabase-gateway` | `nginx:alpine`           | Single origin routing to the three above          |

No realtime / storage / functions / analytics — only what CHEESE uses.

## Setup (three steps)

### 1. Run the script

```bash
cheese setup-supabase
```

Idempotent. It creates `~/.config/cheese/supabase.env` and opens it so you can
set **`CHEESE_AUTH_ALLOWED_DOMAINS`** (comma-separated email domains allowed to
register, e.g. `customer.com,partner.org`) and confirm **`SUPABASE_PUBLIC_URL`**
(the origin browsers will hit). It then generates all secrets, starts the
Supabase stack, loads the schema + RLS policies + the domain-restriction
trigger, and wires the main stack's config — including selecting the correct
UI image variant (next step) automatically.

Re-running it later is safe: it keeps existing secrets and users, and
re-applies whatever you changed (e.g. the domain list).

### 2. Use the auth-enabled UI image (required)

The login UI is compiled into the CHEESE UI image at build time — the default
image doesn't contain it, and no setting can switch it on at runtime. Accounts
need the `-auth` variant of the UI image; `setup-supabase` already selected the
right tag for your channel, so this is just a pull:

```bash
cheese update-images
```

> ⚠️ The generic `-auth` images render the login screen but are built against
> placeholder Supabase values. For a **working** login, DeepMedChem publishes an
> image baked for your deployment — send us the `SUPABASE_PUBLIC_URL` and
> `ANON_KEY` from your `~/.config/cheese/supabase.env`. The anon key is public
> by design (every browser gets it anyway) — safe to share; your real secrets
> never leave the box.

### 3. Restart

```bash
cheese stop && cheese start
```

`cheese start` now brings Supabase up before the core stack. Users can register
(allowed-domain email), sign in, and see only their own history.

## Verify

```bash
# All six Supabase containers up and healthy:
docker compose -p cheese-supabase ps

# Gateway listens on loopback only (no new off-box exposure):
ss -ltn 'sport = :8000'

# Registration policy: sign up with an email outside your allow-list → rejected.
# Isolation: create two accounts, do something in each → each sees only its
# own data. (Database RLS, not a UI filter.)
```

Admin dashboard: open `SUPABASE_PUBLIC_URL` in a browser — Studio, behind the
`DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD` from `supabase.env` (and behind your
IdP too, when the SSO perimeter is on).

## The two URLs

Browsers and CHEESE's own services reach Supabase by different paths — hence
two values in the config, both managed by `setup-supabase`:

| Variable | Used by | Value |
|---|---|---|
| `SUPABASE_URL` | CHEESE services, in-network | `http://supabase-gateway:8000` |
| `SUPABASE_PUBLIC_URL` | users' browsers | `https://<your-host>/supabase` with SSO, else `http://<host>:8000` |

The UI hands the public URL + anon key to the browser at runtime, so the same
UI image works if you later change the public origin (just re-run
`setup-supabase` and restart).

## With the SSO perimeter

If you run the corporate-IdP perimeter ([docs/custom-auth-setup.md](custom-auth-setup.md)),
Supabase is served as `https://<your-host>/supabase/` through the same
`auth_request` gate as the UI — nothing reaches it without passing your IdP,
and the gateway port stays on loopback. `setup-supabase` detects `NGINX=true`
and sets `SUPABASE_PUBLIC_URL` accordingly. The two layers compose: the IdP
controls who reaches the app at all; accounts isolate each user's data once
inside.

## Operations

```bash
cheese start-supabase            # bring Supabase up
cheese stop-supabase             # stop it; user data PERSISTS in the volume
cheese stop-supabase --wipe      # stop AND delete all users + per-user data
docker compose -p cheese-supabase ps          # health
docker logs supabase-auth --tail 50           # signup/login debugging
```

- **Change allowed domains:** edit `CHEESE_AUTH_ALLOWED_DOMAINS` in
  `supabase.env`, re-run `cheese setup-supabase`. Keeps secrets and users.
- **Rotate a secret:** blank it back to `__GENERATED__` in `supabase.env`,
  re-run setup. Rotating `JWT_SECRET` regenerates the API keys and signs
  everyone out (they just log in again).
- **Reset a user's password:** from Studio (no SMTP → no self-service reset;
  add SMTP env to `supabase-auth` later if you want it).
- **Disable accounts:** move `supabase.env` aside (e.g.
  `mv supabase.env supabase.env.off`) and restart — `cheese start` only starts
  Supabase when that file exists. Move it back to re-enable; users and data are
  untouched.
- **Backup:** snapshot the `cheese-supabase_supabase-db-data` volume (standard
  `docker run --rm -v ...:/data ... tar` or your volume-backup tooling).

## Security posture

- **Everything runs on your host.** A slim self-hosted Supabase (Postgres +
  auth + REST, images from public registries) as its own compose project next
  to CHEESE. No phone-home, no external calls, no telemetry leaving the box.
- **Nothing new is exposed off-box by default.** The only published port is the
  Supabase gateway, bound to `127.0.0.1`. With the SSO perimeter
  ([docs/custom-auth-setup.md](custom-auth-setup.md)) browsers reach Supabase as
  a path on the main HTTPS origin, behind your IdP — nginx stays the single
  off-box entrypoint.
- **Isolation is enforced in the database**, not in the UI: Postgres Row-Level
  Security with `auth.uid() = user_id` policies. A user's requests physically
  cannot read or write another user's rows, regardless of what any client sends.
- **Registration is closed by default.** Only emails under the domains you
  allow-list can sign up, enforced by a database trigger — it covers every
  signup path, not just the web form.
- **User data lives in one named Docker volume** on your host
  (`cheese-supabase_supabase-db-data`). Back it up like any volume; wipe it with
  one command (below).
- **Secrets are generated locally** at setup into
  `~/.config/cheese/supabase.env` (DB password, JWT secret, API keys, dashboard
  password). Keep it `chmod 600`. Rotation is supported (below).
- **No SMTP** means no password-reset or confirmation emails: accounts work
  instantly; an admin resets passwords from the bundled dashboard.

## Notes & limitations

- Anyone who can reach the login page *and* has an allowed-domain email can
  self-register. Combine with the SSO perimeter (or network controls) to gate
  who reaches the page at all.
- Supabase image versions are pinned in `config/supabase.env.template`; bump
  them there deliberately — don't track `latest`.
- Accounts isolate **data**; they don't gate functionality — every signed-in
  user gets the full product. There is no billing or tier system in this
  deployment, and nothing to configure about it.
