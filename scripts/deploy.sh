#!/usr/bin/env bash
# One-shot deploy. Safe to re-run.
#
# Steps:
#   1. Verify docker + docker compose v2.
#   2. Generate .env if missing (delegates to scripts/gen-env.sh).
#   3. Ensure deploy-dir nginx/conf.d/ and data-dir subtrees exist.
#   4. Render one nginx server block per served domain.
#   5. Bring up postgres/redis, then create the Logto database and role if
#      single sign-on is enabled.
#   6. Verify BYO certificates, then bootstrap any Let's Encrypt ones.
#   7. docker compose pull + up -d with the profiles .env asks for.
#   8. Install the backup crontab entry when BACKUP_CRON is set.
#   9. Print health status.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_PREFIX=deploy
# shellcheck source=scripts/_lib.sh
. "$REPO_ROOT/scripts/_lib.sh"

command -v docker >/dev/null 2>&1 || die "docker is required."
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required."

if [[ ! -f .env ]]; then
    log "no .env found, generating one..."
    bash scripts/gen-env.sh
else
    log ".env already exists, keeping it."
fi

load_env
build_compose_cmd

log "preparing host directories..."
log "  deploy dir: $REPO_ROOT"
log "  data dir:   $DATA_ROOT"
CERT_DIRS=()
while read -r domain; do
    [[ -n "$domain" ]] && CERT_DIRS+=("$(cert_dir "$domain")")
done < <(served_domains)
mkdir -p \
    "$DATA_ROOT/app" \
    "$DATA_ROOT/logs" \
    "$DATA_ROOT/postgres" \
    "$DATA_ROOT/redis" \
    "$DATA_ROOT/backups" \
    "$DATA_ROOT/nginx/www" \
    "$DATA_ROOT/nginx/logs" \
    "${CERT_DIRS[@]}" \
    || die "could not create $DATA_ROOT subtree (permission? run with sudo or pre-create the dir)."

render_nginx_configs

log "pulling images..."
"${COMPOSE[@]}" pull

# Logto needs its database to exist before its first start, and the postgres
# volume is already initialised so /docker-entrypoint-initdb.d will never run
# again. Create it here instead, idempotently.
if logto_enabled; then
    log "starting postgres to provision the Logto database..."
    "${COMPOSE[@]}" up -d postgres

    log "waiting for postgres to accept connections (up to 120s)..."
    deadline=$(( $(date +%s) + 120 ))
    until "${COMPOSE[@]}" exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
        [[ $(date +%s) -lt $deadline ]] || die "postgres did not become ready in time."
        sleep 3
    done

    log "ensuring role '${LOGTO_DB_USER}' and database '${LOGTO_DB_NAME}' exist..."
    # The role must OWN the database: since PostgreSQL 15 the public schema no
    # longer grants CREATE to PUBLIC, and Logto's schema seeding fails without it.
    # The password is re-applied on every run so .env stays the single source of
    # truth even after it is rotated.
    escaped_password="${LOGTO_DB_PASSWORD//\'/\'\'}"
    "${COMPOSE[@]}" exec -T postgres \
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<SQL || die "could not provision the Logto database."
DO \$\$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = '${LOGTO_DB_USER}') THEN
        ALTER ROLE ${LOGTO_DB_USER} LOGIN PASSWORD '${escaped_password}';
    ELSE
        CREATE ROLE ${LOGTO_DB_USER} LOGIN PASSWORD '${escaped_password}';
    END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${LOGTO_DB_NAME} OWNER ${LOGTO_DB_USER}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${LOGTO_DB_NAME}')\gexec
SQL
    log "Logto database ready."
fi

# BYO certificates first: a missing file here is a hard stop, and finding out
# before spending an ACME round trip is cheaper.
require_byo_certs

if any_letsencrypt; then
    log "bootstrapping Let's Encrypt certificates where missing..."
    bash scripts/init-letsencrypt.sh
fi

# Only meaningful once every server block has a certificate to point at, which
# is why this runs after the bootstrap rather than straight after rendering.
verify_nginx_config

log "starting stack..."
"${COMPOSE[@]}" up -d --remove-orphans

reload_nginx

# Keeps a single tagged crontab line in sync with BACKUP_CRON. An empty
# BACKUP_CRON means the operator schedules backups themselves, so leave the
# user's crontab untouched.
if [[ -n "${BACKUP_CRON:-}" ]]; then
    if command -v crontab >/dev/null 2>&1; then
        marker="# new-api-backup (managed by scripts/deploy.sh)"
        entry="${BACKUP_CRON} cd ${REPO_ROOT} && ./scripts/backup.sh >> ${DATA_ROOT}/backups/backup.log 2>&1 ${marker}"
        tmp_cron="$(mktemp)"
        crontab -l 2>/dev/null | grep -vF "$marker" > "$tmp_cron" || true
        printf '%s\n' "$entry" >> "$tmp_cron"
        crontab "$tmp_cron"
        rm -f "$tmp_cron"
        log "backup schedule installed: $BACKUP_CRON"
    else
        warn "crontab not available; skipping backup schedule. Run scripts/backup.sh from your own scheduler."
    fi
else
    log "BACKUP_CRON is empty; leaving the crontab alone."
fi

log "waiting for new-api to report healthy (up to 120s)..."
deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $deadline ]]; do
    status=$(docker inspect -f '{{.State.Health.Status}}' new-api 2>/dev/null || echo "starting")
    if [[ "$status" == "healthy" ]]; then
        log "new-api is healthy."
        break
    fi
    sleep 3
done

"${COMPOSE[@]}" ps

log "deploy complete — https://${DOMAIN_NAME}/"
if logto_enabled; then
    log "  Logto endpoint: https://${LOGTO_DOMAIN}/"
    log "  Logto console:  https://${LOGTO_ADMIN_DOMAIN}/"
fi
