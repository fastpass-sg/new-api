#!/usr/bin/env bash
# One-shot deploy. Safe to re-run.
#
# Steps:
#   1. Verify docker + docker compose v2.
#   2. Ensure deploy-dir nginx/conf.d/ and data-dir subtrees exist.
#   3. Generate .env if missing (delegates to scripts/gen-env.sh).
#   4. Render nginx/conf.d/new-api.conf from the template using ${DOMAIN_NAME}.
#   5. Bootstrap Let's Encrypt certs if not yet issued.
#   6. docker compose pull + up -d.
#   7. Print health status.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf "[deploy] %s\n" "$*"; }
die() { printf "[deploy] %s\n" "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required."
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required."

if [[ ! -f .env ]]; then
    log "no .env found, generating one..."
    bash scripts/gen-env.sh
else
    log ".env already exists, keeping it."
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"
DATA_ROOT="${DATA_ROOT:-/data/newapi_data}"

log "preparing host directories..."
log "  deploy dir: $REPO_ROOT"
log "  data dir:   $DATA_ROOT"
mkdir -p \
    "$DATA_ROOT/app" \
    "$DATA_ROOT/logs" \
    "$DATA_ROOT/postgres" \
    "$DATA_ROOT/redis" \
    "$DATA_ROOT/nginx/certs" \
    "$DATA_ROOT/nginx/www" \
    "$DATA_ROOT/nginx/logs" \
    || die "could not create $DATA_ROOT subtree (permission? run with sudo or pre-create the dir)."

if ! command -v envsubst >/dev/null 2>&1; then
    die "envsubst is required (install gettext-base / gettext)."
fi

log "rendering nginx config for ${DOMAIN_NAME}..."
envsubst '${DOMAIN_NAME}' \
    < nginx/conf.d/new-api.conf.template \
    > nginx/conf.d/new-api.conf

CERT_FILE="$DATA_ROOT/nginx/certs/live/${DOMAIN_NAME}/fullchain.pem"
if [[ ! -s "$CERT_FILE" ]] || \
   ! openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null | grep -qi "let's encrypt"; then
    log "no Let's Encrypt cert found, running init-letsencrypt..."
    bash scripts/init-letsencrypt.sh
fi

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)

log "pulling images..."
"${COMPOSE[@]}" pull

log "starting stack..."
"${COMPOSE[@]}" up -d --remove-orphans

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
