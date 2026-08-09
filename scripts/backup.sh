#!/usr/bin/env bash
# Dump every database this stack owns to ${DATA_ROOT}/backups.
#
# Covers the new-api database and, once single sign-on is live, the Logto
# database. Losing the Logto database locks out every user who bound their
# account to it, so it is backed up on the same schedule as new-api itself.
#
# Dumps use pg_dump's custom format (-Fc): already compressed, and restorable
# selectively with pg_restore. Restore procedure is in docs/deploy/logto-sso.md.
#
# Usage:
#   ./scripts/backup.sh            # dump both databases, then prune old dumps
#   ./scripts/backup.sh --list     # show what is currently stored, newest first
#
# deploy.sh installs this on a schedule when BACKUP_CRON is set in .env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf "[backup] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf "[backup] %s WARN: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf "[backup] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

[[ -f .env ]] || die ".env missing — run scripts/deploy.sh first."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${POSTGRES_USER:?POSTGRES_USER must be set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB must be set in .env}"
DATA_ROOT="${DATA_ROOT:-/data/newapi_data}"
BACKUP_DIR="$DATA_ROOT/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
LOGTO_DB_NAME="${LOGTO_DB_NAME:-logto}"

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)

if [[ "${1:-}" == "--list" ]]; then
    [[ -d "$BACKUP_DIR" ]] || die "no backup directory at $BACKUP_DIR yet."
    ls -lt "$BACKUP_DIR"/*.dump 2>/dev/null || die "no dumps found in $BACKUP_DIR."
    exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1 (only --list is supported)"

command -v docker >/dev/null 2>&1 || die "docker is required."
mkdir -p "$BACKUP_DIR" || die "could not create $BACKUP_DIR (permission?)."

# Fails fast and loudly rather than leaving a truncated dump that looks fine:
# the dump lands on a .partial path and is only renamed once pg_dump exits 0.
dump_database() {
    local db="$1"
    local stamp final partial
    stamp="$(date '+%Y%m%d-%H%M%S')"
    final="$BACKUP_DIR/${db}-${stamp}.dump"
    partial="${final}.partial"

    log "dumping $db..."
    if ! "${COMPOSE[@]}" exec -T postgres \
            pg_dump -U "$POSTGRES_USER" -d "$db" -Fc > "$partial"; then
        rm -f "$partial"
        die "pg_dump failed for $db. Is the stack running? (docker compose ps)"
    fi

    if [[ ! -s "$partial" ]]; then
        rm -f "$partial"
        die "pg_dump produced an empty file for $db."
    fi

    mv "$partial" "$final"
    log "wrote $final ($(du -h "$final" | cut -f1))"
}

dump_database "$POSTGRES_DB"

# Logto is optional and arrives later than new-api, so its absence is normal.
if "${COMPOSE[@]}" exec -T postgres \
        psql -U "$POSTGRES_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '$LOGTO_DB_NAME'" 2>/dev/null \
        | grep -q 1; then
    dump_database "$LOGTO_DB_NAME"
else
    log "database $LOGTO_DB_NAME does not exist yet; skipping."
fi

log "pruning dumps older than $RETENTION_DAYS day(s)..."
pruned="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -type f -mtime "+$RETENTION_DAYS" -print -delete | wc -l | tr -d ' ')"
log "pruned $pruned old dump(s)."

# Leftover .partial files mean an earlier run died mid-dump. Surface that rather
# than letting them accumulate silently.
stale="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.partial' -type f | wc -l | tr -d ' ')"
if [[ "$stale" != "0" ]]; then
    warn "$stale interrupted dump(s) left in $BACKUP_DIR (*.partial). Investigate and remove them."
fi

log "backup complete."
