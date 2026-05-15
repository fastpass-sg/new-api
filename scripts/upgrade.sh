#!/usr/bin/env bash
# One-shot upgrade. Pulls newer images and restarts services.
#
# Flags:
#   --skip-git   Skip the leading `git pull --ff-only`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf "[upgrade] %s\n" "$*"; }
die() { printf "[upgrade] %s\n" "$*" >&2; exit 1; }

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

command -v envsubst >/dev/null 2>&1 || die "envsubst is required."

log "re-rendering nginx config..."
envsubst '${DOMAIN_NAME}' \
    < nginx/conf.d/new-api.conf.template \
    > nginx/conf.d/new-api.conf

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)

log "pulling images..."
"${COMPOSE[@]}" pull

log "applying changes..."
"${COMPOSE[@]}" up -d --remove-orphans

log "pruning dangling images..."
docker image prune -f >/dev/null

"${COMPOSE[@]}" ps

log "upgrade complete."
