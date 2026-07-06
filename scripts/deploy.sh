#!/usr/bin/env bash
# One-shot deploy. Safe to re-run.
#
# Steps:
#   1. Verify docker + docker compose v2.
#   2. Ensure deploy-dir nginx/conf.d/ and data-dir subtrees exist.
#   3. Generate .env if missing (delegates to scripts/gen-env.sh).
#   4. Render nginx/conf.d/new-api.conf from the template using ${DOMAIN_NAME}.
#   5. CERT_MODE=byo   → verify cert files exist and report expiry.
#      CERT_MODE=letsencrypt → bootstrap via init-letsencrypt.sh.
#   6. docker compose pull + up -d (with --profile letsencrypt when applicable).
#   7. Print health status.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf "[deploy] %s\n" "$*"; }
warn() { printf "[deploy] WARN: %s\n" "$*" >&2; }
die()  { printf "[deploy] %s\n" "$*" >&2; exit 1; }

# Inspects an x509 cert and emits a warning when expiry < 30 days, errors when
# < 7 days. Used by both deploy.sh and upgrade.sh.
check_cert_expiry() {
    local cert="$1"
    [[ -s "$cert" ]] || { warn "cert file missing: $cert"; return 1; }

    local end_date end_epoch now_epoch days_left
    end_date="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [[ -n "$end_date" ]] || { warn "could not parse cert at $cert"; return 1; }

    # GNU date (Linux deploy targets). macOS uses BSD date; fall back gracefully.
    end_epoch="$(date -d "$end_date" +%s 2>/dev/null \
              || date -j -f "%b %e %T %Y %Z" "$end_date" +%s 2>/dev/null \
              || echo 0)"
    now_epoch="$(date +%s)"
    if [[ "$end_epoch" -eq 0 ]]; then
        warn "could not compute days remaining for $cert (date parsing failed). Expiry string: $end_date"
        return 0
    fi
    days_left=$(( (end_epoch - now_epoch) / 86400 ))

    if [[ $days_left -lt 7 ]]; then
        die "TLS cert at $cert expires in $days_left day(s) ($end_date). Renew it before redeploying."
    elif [[ $days_left -lt 30 ]]; then
        warn "TLS cert at $cert expires in $days_left day(s) ($end_date). Plan a renewal."
    else
        log "TLS cert OK — $days_left day(s) remaining (expires $end_date)."
    fi
}

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
CERT_MODE="${CERT_MODE:-byo}"

case "$CERT_MODE" in
    byo|letsencrypt) ;;
    *) die "CERT_MODE must be 'byo' or 'letsencrypt' (got: $CERT_MODE)" ;;
esac
log "cert mode: $CERT_MODE"

log "preparing host directories..."
log "  deploy dir: $REPO_ROOT"
log "  data dir:   $DATA_ROOT"
mkdir -p \
    "$DATA_ROOT/app" \
    "$DATA_ROOT/logs" \
    "$DATA_ROOT/postgres" \
    "$DATA_ROOT/redis" \
    "$DATA_ROOT/nginx/certs/live/${DOMAIN_NAME}" \
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
KEY_FILE="$DATA_ROOT/nginx/certs/live/${DOMAIN_NAME}/privkey.pem"

if [[ "$CERT_MODE" == "byo" ]]; then
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        die "CERT_MODE=byo but cert/key not found. Place them at:
    $CERT_FILE
    $KEY_FILE
then re-run ./scripts/deploy.sh"
    fi
    check_cert_expiry "$CERT_FILE"
else
    # letsencrypt mode: bootstrap if missing, then verify expiry on existing certs.
    if [[ ! -s "$CERT_FILE" ]] || \
       ! openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null | grep -qi "let's encrypt"; then
        log "no Let's Encrypt cert found, running init-letsencrypt..."
        bash scripts/init-letsencrypt.sh
    fi
    check_cert_expiry "$CERT_FILE"
fi

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)
if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    COMPOSE+=(--profile letsencrypt)
fi

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
