#!/usr/bin/env bash
# One-shot upgrade. Pulls newer images and restarts services.
#
# Both new-api and Logto apply schema migrations on start, and neither is
# reversible by simply pulling the old image again. This takes a database dump
# first unless told not to.
#
# Flags:
#   --skip-git      Skip the leading `git pull --ff-only`.
#   --skip-backup   Skip the pre-upgrade database dump. Only for a re-run right
#                   after a successful backup.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_PREFIX=upgrade
# shellcheck source=scripts/_lib.sh
. "$REPO_ROOT/scripts/_lib.sh"

SKIP_GIT=0
SKIP_BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --skip-git)    SKIP_GIT=1 ;;
        --skip-backup) SKIP_BACKUP=1 ;;
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

load_env
build_compose_cmd

# Taken before anything is pulled or restarted, so the dump matches the schema
# the currently running images wrote.
if [[ $SKIP_BACKUP -eq 0 ]]; then
    log "taking a pre-upgrade database dump..."
    bash scripts/backup.sh || die "backup failed; refusing to upgrade. Pass --skip-backup to override."
else
    warn "--skip-backup given; upgrading without a fresh dump."
fi

render_nginx_configs
verify_nginx_config

while read -r domain; do
    [[ -n "$domain" ]] || continue
    check_cert_expiry "$(cert_file "$domain")" || true
done < <(served_domains)

# Picks up domains added to .env since the last run; existing certs are skipped.
if any_letsencrypt; then
    bash scripts/init-letsencrypt.sh || warn "Let's Encrypt bootstrap reported a problem; continuing with existing certs."
fi

log "pulling images..."
"${COMPOSE[@]}" pull

log "applying changes..."
"${COMPOSE[@]}" up -d --remove-orphans

reload_nginx

log "pruning dangling images..."
docker image prune -f >/dev/null

"${COMPOSE[@]}" ps

log "upgrade complete."
