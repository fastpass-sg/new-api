# Single sign-on with Logto

Runbook for putting Logto in front of new-api as an identity provider, and for
the rc.24 upgrade that has to happen first.

Design rationale and the trade-offs behind each choice are in
`docs/superpowers/specs/2026-08-10-logto-sso-design.md`. This file is the
procedure.

## What this gives you, and what it does not

Logto becomes the identity provider. new-api joins as an OIDC relying party, and
any other site can join the same way later. A user who signs in at one place is
signed in at the others.

It does **not** give another site access to a user's new-api API keys or quota.
Single sign-on establishes who someone is; it grants no authority over their
new-api account. Logto's access tokens are rejected by every new-api user
endpoint. To let another site spend a user's quota, have that user create a key
in new-api scoped to specific models with its own limit and expiry, and paste it
into the other site. That key can then read its own balance and usage directly
from `GET /api/usage/token`, which accepts the key itself and permits
cross-origin requests.

Do not use a personal access token for this. It is a single field on the user
row with no expiry and no scope: generating a new one silently invalidates the
old one, and anyone holding it has full control of the account.

## Before you start

- Both Logto domains must already resolve to this host. Let's Encrypt validates
  over port 80, so DNS has to be correct first.
- A real transactional email service (SES, Postmark, Resend, or a domestic
  equivalent) with SPF, DKIM and DMARC in place. Email-only registration means a
  verification mail in the spam folder is a lost user. Do not use self-hosted
  SMTP or a personal mailbox as a relay.
- A recent backup. `./scripts/backup.sh` and confirm it wrote a dump.

Run the three phases in separate maintenance windows. Each is independently
verifiable and independently reversible; together they are not.

---

## Phase 1 — Upgrade to v1.0.0-rc.24

**This is not a routine version bump.** Upstream replaced dashboard sessions
with stateless tokens plus a refresh cookie (#6329). Consequences:

- **Every signed-in user is signed out once** when the new image starts.
- `SESSION_COOKIE_SECURE=true` now also enables strict OriginGuard and requires
  every trusted HTTPS origin to be listed. `deploy.sh` derives
  `SESSION_COOKIE_TRUSTED_URL` from `DOMAIN_NAME` when it is blank, so the two
  cannot drift apart. new-api refuses to start if the pair is inconsistent.
- `TRUSTED_PROXIES` is new. Left empty it trusts loopback and the RFC1918 ranges,
  which covers the compose bridge, and prints a startup warning. Set it to the
  bridge subnet to silence that:
  ```
  docker network inspect new-api_new-api-network -f '{{(index .IPAM.Config 0).Subnet}}'
  ```
- OAuth state moved into an `auth_flows` table with an explicit login/bind
  intent, and a bind is tied to the session that started it. This is what makes
  Phase 4 safe.

Steps:

```bash
./scripts/backup.sh                 # verify it prints a dump path
git pull --ff-only
./scripts/upgrade.sh                # takes its own dump first
```

Verify before continuing: sign in, create an API key, make a relay call with it,
open the admin dashboard. Existing sessions being logged out is expected.

---

## Phase 2 — Bring up Logto

Edit `.env`:

```
LOGTO_ENABLED=true
LOGTO_DOMAIN=auth.example.com
LOGTO_ADMIN_DOMAIN=auth-admin.example.com
LOGTO_ADMIN_ALLOW="203.0.113.4"      # optional; quote it, spaces separate entries
```

`LOGTO_DB_PASSWORD` was generated when `.env` was created. If yours predates
that, add one: `openssl rand -hex 32`.

```bash
./scripts/deploy.sh
```

This creates the `logto` role and database inside the existing Postgres,
requests a certificate for each new domain, renders their nginx server blocks,
and starts the container. The main site keeps its existing certificate
throughout — `CERT_MODE` governs it, `LOGTO_CERT_MODE` governs the new domains,
and the bootstrap only ever touches domains it was asked to handle.

Verify:

```bash
curl -s https://auth.example.com/oidc/.well-known/openid-configuration | jq .issuer
```

Then open `https://auth-admin.example.com` and create the admin account. Do this
promptly: until you do, the console is unclaimed.

`LOGTO_ADMIN_ALLOW` is a second gate in front of Logto's own login, not a
replacement for it. Leaving it empty is a supported choice, just a weaker one.

---

## Phase 3 — Connect new-api to Logto

### Preflight

In new-api, System Settings → the **server address** must equal
`https://<your main domain>` character for character. The token exchange builds
its `redirect_uri` from this value, and OAuth requires it to match the
authorization request exactly. Trailing slashes, `http` versus `https`, and
`www` inconsistencies all break it.

**Do not change this value to fix something else.** Passkey RPID is derived from
it, so changing it invalidates every passkey already registered.

### In the Logto console

1. Applications → Create → **Traditional Web**. This type is required: new-api
   exchanges the code with a client secret and does not send PKCE, so a SPA
   application fails on the missing `code_verifier`.
2. Redirect URI: `https://<your main domain>/oauth/logto`
3. Post sign-out redirect URI: `https://<your main domain>/sign-in`. Required
   for sign out to end the Logto session — Logto rejects a logout request whose
   redirect it has not been told to allow, stranding the user on an error page.
4. Note the App ID and App Secret.
5. Add the SMTP connector using your transactional email credentials.
6. Enable CAPTCHA (Turnstile or reCAPTCHA Enterprise). It covers the identifier,
   password, verification-code, registration and password-recovery flows. It
   does **not** cover magic-link or passkey sign-in.
7. The disposable-email domain blocklist is a Logto Cloud feature and is absent
   from the self-hosted build. Sync a public disposable-domain list into the
   custom blocklist if free quota is at stake.

### In new-api

System Settings → Authentication → Custom OAuth Provider. Use this rather than
the built-in OIDC option: its HTTP timeout is 20s against the built-in path's 5s,
`auth_style` auto-detects how the client secret must be sent, bindings live in
their own table so they can be undone, and the single built-in OIDC slot stays
free.

Read the real endpoints from the discovery document rather than copying them:

```bash
curl -s https://auth.example.com/oidc/.well-known/openid-configuration \
  | jq '{authorization_endpoint, token_endpoint, userinfo_endpoint, end_session_endpoint}'
```

| Field | Value |
|---|---|
| Name | Logto |
| Slug | `logto` — this determines the callback path `/oauth/logto` |
| Client ID / Secret | from the Logto application |
| Well-known | `https://auth.example.com/oidc/.well-known/openid-configuration` |
| Authorization / Token / User info | press Discover, or copy from the command above |
| Scopes | `openid profile email` |
| User ID field | `sub` |
| Username field | `preferred_username` |
| Display name field | `name` |
| Email field | `email` |
| Logout endpoint | `https://auth.example.com/oidc/session/end` |
| Auth style | `0` (auto detect) |

The field mapping is identical to the built-in Keycloak preset, because Logto
returns the same standard claims.

Discover fills the logout endpoint too, from `end_session_endpoint`. Leaving it
empty is a valid choice: sign out then only ends the new-api session and the
Logto one survives. Setting it requires the post sign-out redirect URI from step
3 above, and only takes effect on the fork's image.

Test with a throwaway Logto account before announcing anything.

---

## Phase 4 — Migrating existing users

Nothing is forced and there is no deadline.

Existing users go to Profile → Account Bindings and press Bind next to Logto.
That links their Logto identity to their existing account, preserving quota,
keys and history. Password sign-in keeps working, before and after.

Keep the root account unbound from Logto. It is the way back in if Logto is
unavailable.

### If a user reports "email already in use"

They created a Logto account with the same address as their existing new-api
account before binding. new-api will not silently merge two accounts on a
matching address, which is correct: an unverified address would otherwise be an
account takeover.

Recovery: sign in to new-api with their password, then bind from Profile →
Account Bindings. The Logto account they just made is reused, not duplicated.

### Signing out

Signing out ends the Logto session too, provided the provider has a **Logout
Endpoint** configured (see Phase 3). Without it, sign out is local only: the
Logto session survives, so pressing sign-in returns the user immediately and
looks like the sign out failed.

This is a fork patch — upstream new-api has no RP-initiated logout at all — so it
only works when running the fork's image. See the image note in `.env.example`.

Logging out of another application that shares this Logto tenant does **not**
sign the user out of new-api. That direction needs a backchannel logout endpoint
in new-api, which does not exist.

### Review free quota before opening registration

Signing up through Logto is easier than the existing email verification flow,
and this gateway bills real tokens. Reconsider what a brand-new account is
given.

---

## Backups

`scripts/backup.sh` dumps the new-api database and, once it exists, the Logto
database, into `${DATA_ROOT}/backups` in pg_dump's custom format. `deploy.sh`
installs a crontab entry from `BACKUP_CRON`, and `upgrade.sh` takes a dump
before every upgrade.

```bash
./scripts/backup.sh            # run now
./scripts/backup.sh --list     # what is stored, newest first
```

Losing the Logto database locks out every user who bound their account to it. It
matters more than the new-api database, not less.

**A backup you have never restored is a hypothesis.** Rehearse it:

```bash
# Restore into a scratch database and confirm it is readable.
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres \
  createdb -U "$POSTGRES_USER" restore_check
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres \
  pg_restore -U "$POSTGRES_USER" -d restore_check --no-owner \
  < /data/newapi_data/backups/<file>.dump
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres \
  psql -U "$POSTGRES_USER" -d restore_check -c '\dt' | head
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres \
  dropdb -U "$POSTGRES_USER" restore_check
```

---

## Troubleshooting

Turn on debug logging in new-api first; the OAuth path logs the token endpoint,
the `redirect_uri` it built, HTTP status codes, and the `sub` and `email` it
received.

| Symptom | Cause |
|---|---|
| `redirect_uri_mismatch` in the Logto log | The new-api server address does not exactly match the URL users visit, or the Logto redirect URI does not end in `/oauth/logto` |
| Empty access token | Same as above, or the client authentication style is rejected — set auth style to 0 |
| `empty fields (sub=, email=)` | Logto returned no email. Check the `email` scope and that the account has an address |
| User info status is not 200 | Wrong endpoint, or the access token was rejected |
| Connection failure or timeout | Logto unreachable from the new-api container. Both are on the same compose network; check `docker compose ps` |
| nginx will not start after a config change | Run `docker compose -f docker-compose.prod.yml exec nginx nginx -t`. `deploy.sh` and `upgrade.sh` run this before restarting anything |
| Logto container restart loop | Check `docker compose logs logto`. Usually the database role or ownership; `deploy.sh` recreates both idempotently |
| Image pull fails with `unauthorized` | The ghcr.io package is private. GHCR publishes privately by default even from a public repository; make the package public once in its settings, or `docker login ghcr.io` with a read:packages token |

---

## Rollback

| Phase | How to undo |
|---|---|
| 1 | Set `NEW_API_IMAGE` back to `calciumion/new-api:v1.0.0-rc.17` **and restore the pre-upgrade dump**. rc.24's AutoMigrate adds columns, so reverting the image alone is not enough |
| 2 | `LOGTO_ENABLED=false` then `./scripts/deploy.sh`. The Logto server blocks are removed and its container stops. The main site is unaffected — nginx never depends on Logto, and its upstream only exists while it is enabled. The database is left intact |
| 3 | Disable the custom OAuth provider in new-api's admin settings. Password sign-in is unaffected, existing bindings stay in the table, and re-enabling restores them |

Phase 3 is the safe one to reverse under pressure. Phase 1 is the expensive one:
do not start it without a verified dump.
