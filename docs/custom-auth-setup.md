# SSO for CHEESE on-prem (corporate IdP)

Put an authenticating reverse proxy (nginx + oauth2-proxy) in front of CHEESE:
every visitor signs in with **your** identity provider (Azure/Entra ID, Okta, or
any OIDC IdP) before a single request reaches the stack. Every authenticated
user gets the full product — there are no feature tiers on-prem.

## Security posture

- **One exposed port.** With SSO on, nginx is the only service on a public
  interface (443, plus 80 → 443 redirect). Everything else — UI, API, database,
  file server, and Supabase if you use accounts — stays on the internal Docker
  network / loopback.
- **Auth at the perimeter.** Every route (`/`, `/cheese-api/`,
  `/cheese-fileserver/`, `/supabase/`) is behind `auth_request`; nothing is
  reachable unauthenticated.
- **Access control is yours.** Who gets in = your IdP app assignment plus the
  `OAUTH2_PROXY_EMAIL_DOMAINS` allow-list. CHEESE adds no accounts of its own in
  this mode.
- **No phone-home.** oauth2-proxy talks only to your IdP; identity is checked at
  the perimeter and not used for tracking inside CHEESE.

## Prerequisites

- A working install (`cheese start` brings the stack up).
- A DNS name for the host, e.g. `cheese.customer.com`.
- A TLS certificate + key for that name (self-signed is fine for a PoC).
- An OIDC app registration in your IdP with client id, client secret, and
  redirect URL `https://<your-host>/oauth2/callback`.

## Setup (three steps)

### 1. Connect your IdP

```bash
cheese configure-oauth2
```

Opens `~/.config/cheese/oauth2.env`. Base it on the matching template —
`config/oauth2.env.template` (Entra ID) or `config/oauth2-okta.env.template`
(Okta) — and set:

| Key | Value |
|---|---|
| `OAUTH2_PROXY_CLIENT_ID` / `_CLIENT_SECRET` | from the IdP app registration |
| `OAUTH2_PROXY_OIDC_ISSUER_URL` | your issuer, e.g. `https://login.microsoftonline.com/<tenant_id>/v2.0` |
| `OAUTH2_PROXY_REDIRECT_URL` | `https://<your-host>/oauth2/callback` |
| `OAUTH2_PROXY_EMAIL_DOMAINS` | your domain(s), e.g. `customer.com` — or `*` to accept anyone your IdP authenticates |
| `OAUTH2_PROXY_COOKIE_SECRET` | `python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode())'` |

### 2. Configure TLS + routing

```bash
cheese configure-nginx
```

Opens `~/.config/cheese/nginx.conf` (based on `config/nginx.conf.template`, or
`config/nginx-okta.conf.template` for Okta — same proxy layout, only the logout
redirect differs). Replace `domain.com` with `<your-host>`, then provide the
certificate and key when prompted (mounted read-only into the container).

The template already routes everything through `auth_request` — you don't need
to add locations.

### 3. Turn it on

In `~/.config/cheese/cheese-env-file.conf`:

```
NGINX=true
IP=<your-host>
```

Then:

```bash
cheese stop && cheese start
```

`cheese start` now also brings up nginx + oauth2-proxy and prints the entry
point: `https://<your-host>/`.

## Verify

```bash
# Unauthenticated request → redirect to your IdP:
curl -skI https://<your-host>/ | head -3

# Both perimeter containers up:
docker compose -p cheese ps nginx oauth2-proxy

# Watch a test sign-in succeed:
docker compose -p cheese logs -f oauth2-proxy
```

After signing in, the full UI loads — every feature, every configured database.

## Notes

- **Per-user accounts / private workspaces are a separate, compatible feature.**
  SSO controls who gets in; behind it, all users share one workspace. If you
  also want per-user isolation, run `cheese setup-supabase`
  ([docs/supabase-auth-setup.md](supabase-auth-setup.md)). With the perimeter
  on, Supabase is served through nginx at `https://<your-host>/supabase` and is
  never exposed on its own port.
- **Downloads** are proxied through nginx in SSO mode (also behind
  `auth_request`); the raw file-server port stays internal — don't publish it.
- The perimeter images are public upstreams (`nginx:alpine`,
  `quay.io/oauth2-proxy/oauth2-proxy`) — no CHEESE registry access needed for
  this part.
- There are no auth/tier flags to hand-edit in `cheese-env-file.conf`; the two
  settings above are the entire configuration.
