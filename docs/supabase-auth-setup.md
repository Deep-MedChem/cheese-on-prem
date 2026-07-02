# On-prem user accounts with self-hosted Supabase

This sets up **real per-user accounts** on-prem — every user signs in with their
own email/password and gets their **own private space** (their searches,
downloads, quotations and ADMET history are visible only to them), while every
account still has full ("premium") access to the whole product.

It needs nothing from the customer's cluster except Docker — no Azure, no
corporate IdP, no SMTP. Authentication is Supabase's own email/password (GoTrue),
self-hosted alongside CHEESE.

## How it works (and why everyone is still "premium")

Two independent layers:

- **Per-user spaces** come from **Supabase Row-Level Security**. The browser
  signs in, gets a JWT, and writes its rows (`searches`, `downloads`,
  `quotations`, `admet_properties`) straight to Supabase through PostgREST. Each
  table's RLS policy is `auth.uid() = user_id`, so a user can only ever read/write
  their own rows. A `handle_new_user` trigger auto-creates a profile on signup.

- **Everyone is premium** because the orchestrator stays in non-`PRODUCTION`
  mode: regardless of `ENABLE_AUTH`, its `if not PRODUCTION:` branch makes every
  request run as the `universal-cheese` user — full access to all databases, no
  tier/paywall checks (`cheese-orchestrator/.../app.py`). The UI's upsell paths
  are gated behind `ENABLE_STRIPE`, which stays `false`. And to be safe, new
  accounts are created with `account_type = 'premium'` (the on-prem SQL overlay).

So accounts gate *who you are* (and isolate your data); they never downgrade
*what you can do*.

## What gets deployed

A **slim** self-hosted Supabase — only what CHEESE uses — as its own compose
project (`cheese-supabase`) on the shared `cheese-network`:

| Service            | Image                  | Role                                            |
| ------------------ | ---------------------- | ----------------------------------------------- |
| `supabase-db`      | `supabase/postgres`    | Users (`auth.users`) + app tables + RLS         |
| `supabase-auth`    | `supabase/gotrue`      | Email/password signup & login, issues JWTs      |
| `supabase-rest`    | `postgrest/postgrest`  | REST API the browser writes per-user rows through |
| `supabase-meta`    | `supabase/postgres-meta`| Backs Studio                                   |
| `supabase-studio`  | `supabase/studio`      | Admin dashboard (manage/inspect users)          |
| `supabase-gateway` | `nginx:alpine`         | One public origin: `/auth/v1`→auth, `/rest/v1`→rest, `/`→Studio (basic-auth) |

No realtime / storage / functions / analytics / vector — add the official
services later if ever needed.

## Setup

### 1. Run the script

```bash
cheese setup-supabase
```

It will, idempotently:

1. Create `~/.config/cheese/supabase.env` from the template and open it so you can
   set **`CHEESE_AUTH_ALLOWED_DOMAINS`** (comma-separated email domains allowed to
   register, e.g. `customer.com,partner.org`) and confirm **`SUPABASE_PUBLIC_URL`**
   (the origin users' browsers will hit — defaults to `http://<IP>:8000`).
2. Generate all secrets (`POSTGRES_PASSWORD`, `JWT_SECRET`, and the `ANON_KEY` /
   `SERVICE_ROLE_KEY` signed from it, Studio dashboard password).
3. Pull the images and start the Supabase stack.
4. Load the CHEESE schema + the on-prem overlay (premium default + the
   domain-restriction trigger).
5. Wire the main stack's `~/.config/cheese/cheese-env-file.conf`:
   `ENABLE_AUTH=true`, `ENABLE_SUPABASE=true`, `ENABLE_STRIPE=false`,
   `ENABLE_TRACKING=true`, and the `SUPABASE_*` URL/keys (internal `SUPABASE_URL`
   for the orchestrator, `SUPABASE_PUBLIC_URL` for the browser, plus
   `SUPABASE_JWT_ISSUER`).

### 2. Use an auth-enabled UI image  ⚠️ required

The UI's client feature flags are **inlined at build time** (`VITE_ENABLE_AUTH`
in `config/featureFlags.ts`); the default on-prem image is built with
`AUTH=false`, so its login UI is tree-shaken out and **no amount of runtime env
will show it**. You must run the **auth variant** of the UI image, built with:

```
VITE_ENABLE_AUTH=true  VITE_ENABLE_TRACKING=true
VITE_ENABLE_STRIPE=false  VITE_ENABLE_NOTIFICATIONS=false
```

This variant is published per channel with an `-auth` tag suffix, alongside the
base image (see cheese-search-ui `make-on-prem.yml`):

| Channel | Base image | Auth variant |
|---|---|---|
| develop | `…/on-prem/cheese-search-ui/cheese-customer:develop` | `:develop-auth` |
| main    | `…/on-prem/cheese-search-ui/cheese-customer:latest`  | `:latest-auth` |

**You don't select it by hand** — `cheese setup-supabase` sets
`CHEESE_UI_IMAGE_TAG=<channel>-auth` in `cheese-env-file.conf`, and the `ui`
service + `cheese update-images` both honor it (the rest of the stack stays on the
plain channel tag). So after `setup-supabase`, just:

```bash
cheese update-images       # pulls cheese-search-ui:<channel>-auth
cheese stop && cheese start
```

> ⚠️ **Per-deployment Supabase values are baked at build time.** On current
> production code the **browser** reads the Supabase URL + anon key from build-time
> `VITE_*` values. The generic `:develop-auth` / `:latest-auth` images bake
> **placeholders**: they render the login UI, but for a **working** login against
> your self-hosted Supabase you need an auth image with your deployment's values
> baked. Two production-compatible ways to get one:
>
> - **CI**: run the cheese-search-ui `make-on-prem.yml` via `workflow_dispatch` and
>   fill the `supabase_url` / `supabase_anon_key` inputs (your `SUPABASE_PUBLIC_URL`
>   and `ANON_KEY` from `~/.config/cheese/supabase.env`). The anon key is public by
>   design — safe to bake.
> - **Locally**:
>   ```bash
>   docker build -f Dockerfile \
>     --build-arg ENABLE_AUTH=true --build-arg ENABLE_TRACKING=true \
>     --build-arg ENABLE_STRIPE=false --build-arg ENABLE_ANALYTICS=false \
>     --build-arg ENABLE_NOTIFICATIONS=false \
>     --build-arg SUPABASE_URL=<SUPABASE_PUBLIC_URL> \
>     --build-arg SUPABASE_ANON_KEY=<ANON_KEY> \
>     -t <registry>/on-prem/cheese-search-ui/cheese-customer:<channel>-auth .
>   ```
> Verify the flags actually inlined (the bundle must contain `Auth-*.js` /
> `CompleteProfile-*.js` chunks) before shipping.

### 3. Restart the stack

```bash
cheese stop && cheese start
```

`cheese start` auto-starts Supabase whenever `~/.config/cheese/supabase.env`
exists, then brings up the core. Visit the CHEESE UI: users can now register
(with an allowed-domain email), sign in, and see only their own history.

Manage users at `SUPABASE_PUBLIC_URL/` (Studio, behind the dashboard basic-auth
in `supabase.env`).

## The internal-vs-public URL split

The browser and the server reach Supabase by different paths, which is why there
are two URLs:

- `SUPABASE_URL=http://supabase-gateway:8000` — the in-network alias the
  orchestrator and UI **server** use.
- `SUPABASE_PUBLIC_URL` — what the **browser** uses (see the perimeter section
  below for its value). The UI server injects this (+ the anon key) into
  `index.html` as `window.__CHEESE_RUNTIME__` and also serves it at
  `/api/runtime-config`; the client Supabase factory reads it before falling back
  to build-time `VITE_*`.
- `SUPABASE_JWT_ISSUER=<SUPABASE_PUBLIC_URL>/auth/v1` — matches the `iss` GoTrue
  stamps into browser JWTs, so the orchestrator validates them while fetching
  JWKS over the internal URL. GoTrue derives its own issuer/site URL from
  `SUPABASE_PUBLIC_URL` too, so the three always agree. (Only exercised if you
  ever set `PRODUCTION`; under the default universal-cheese mode the orchestrator
  doesn't gate on the token.)

## Supabase behind the nginx perimeter (not exposed off-box)

Supabase does **not** need its own exposed port. The gateway's host port is
loopback-bound (`127.0.0.1:8000` by default, like the rest of the stack), and the
`sso` nginx proxies Supabase as a **path on the main origin**:

```
https://<your-host>/supabase/  →  supabase-gateway:8000   (over cheese-network)
```

- With `NGINX=true`, `cheese setup-supabase` defaults
  `SUPABASE_PUBLIC_URL=https://<IP>/supabase`; supabase-js then calls
  `/supabase/auth/v1/*` and `/supabase/rest/v1/*`, and the nginx `location
  /supabase/` (see `config/nginx*.conf.template`) strips the prefix before
  handing the request to the gateway.
- The location sits behind the same `auth_request /oauth2/auth` as the UI — the
  browser's Supabase calls are same-origin XHRs, so they carry the oauth2 session
  cookie. Nothing reaches Supabase without passing the IdP.
- Studio remains available at `https://<your-host>/supabase/` (IdP + its own
  basic auth), and directly on the box at `http://localhost:8000`.
- nginx is then the **only** off-box path to Supabase: gateway, GoTrue, PostgREST
  and Postgres all stay on `cheese-network`/loopback.

Without the perimeter (`NGINX` unset), the default is the direct gateway origin
`http://<IP>:8000` — fine for on-box testing (`localhost`), but for real users
prefer the perimeter above. Set `BIND_ADDR` to a NIC only if browsers must reach
the gateway directly.

## Operations

```bash
cheese start-supabase           # bring Supabase up
cheese stop-supabase            # stop it; user data PERSISTS in the volume
cheese stop-supabase --wipe     # stop AND delete all users + per-user data
docker compose -p cheese-supabase ps      # health
docker logs supabase-auth --tail 50       # signup/login debugging
```

- **Add/remove allowed domains:** edit `CHEESE_AUTH_ALLOWED_DOMAINS` in
  `supabase.env` and re-run `cheese setup-supabase` (re-applies the trigger;
  keeps existing secrets and users).
- **Rotate a secret:** blank it back to `__GENERATED__` in `supabase.env` and
  re-run setup. Rotating `JWT_SECRET` regenerates the anon/service keys and
  invalidates live sessions (users re-login).
- **No SMTP:** email confirmation is off (`GOTRUE_MAILER_AUTOCONFIRM=true`), so
  accounts work instantly and there's no password-reset email. Reset passwords
  for users from Studio. Add SMTP env to `supabase-auth` later if you want
  self-service reset.

## Notes & limitations

- Signup is open to anyone who can reach the page *with an allowed-domain email*
  (enforced by a DB trigger, so it covers every signup path). Combine with the
  network perimeter (or the `sso` nginx) to control who reaches the page at all.
- Image tags are pinned in `config/supabase.env.template`; bump them there.
- The CHEESE schema is **vendored** at `config/supabase/sql/01-cheese-schema.sql`
  from `cheese-supabase`'s base migration (billing/tier migrations intentionally
  excluded). Re-copy it if the upstream base schema changes.
