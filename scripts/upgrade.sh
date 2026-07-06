#!/usr/bin/env bash
# One-shot upgrade. Pulls newer images and restarts services.
#
# Flags:
#   --skip-git   Skip the leading `git pull --ff-only`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf "[upgrade] %s\n" "$*"; }
warn() { printf "[upgrade] WARN: %s\n" "$*" >&2; }
die()  { printf "[upgrade] %s\n" "$*" >&2; exit 1; }

# Same logic as deploy.sh:check_cert_expiry — warn < 30 days, die < 7 days.
check_cert_expiry() {
    local cert="$1"
    [[ -s "$cert" ]] || { warn "cert file missing: $cert"; return 1; }

    local end_date end_epoch now_epoch days_left
    end_date="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [[ -n "$end_date" ]] || { warn "could not parse cert at $cert"; return 1; }

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
        die "TLS cert at $cert expires in $days_left day(s) ($end_date). Renew it before re-running upgrade."
    elif [[ $days_left -lt 30 ]]; then
        warn "TLS cert at $cert expires in $days_left day(s) ($end_date). Plan a renewal."
    else
        log "TLS cert OK — $days_left day(s) remaining (expires $end_date)."
    fi
}

SKIP_GIT=0
for arg in "$@"; do
    case "$arg" in
        --skip-git) SKIP_GIT=1 ;;
        *) die "unknown flag: $arg" ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker is required."
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required."
[[ -f .env ]] || die ".env missing — run scripts/deploy.sh first."

if [[ $SKIP_GIT -eq 0 ]]; then
    if [[ -d .git ]]; then
        log "git pull --ff-only..."
        git pull --ff-only || die "git pull failed; resolve manually or rerun with --skip-git."
    else
        log "not a git checkout; skipping git pull."
    fi
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"
DATA_ROOT="${DATA_ROOT:-/data/newapi_data}"
CERT_MODE="${CERT_MODE:-byo}"

command -v envsubst >/dev/null 2>&1 || die "envsubst is required."

log "re-rendering nginx config..."
envsubst '${DOMAIN_NAME}' \
    < nginx/conf.d/new-api.conf.template \
    > nginx/conf.d/new-api.conf

check_cert_expiry "$DATA_ROOT/nginx/certs/live/${DOMAIN_NAME}/fullchain.pem" || true

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)
if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    COMPOSE+=(--profile letsencrypt)
fi

log "pulling images..."
"${COMPOSE[@]}" pull

log "applying changes..."
"${COMPOSE[@]}" up -d --remove-orphans

log "pruning dangling images..."
docker image prune -f >/dev/null

"${COMPOSE[@]}" ps

log "upgrade complete."
