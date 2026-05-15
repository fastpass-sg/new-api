#!/usr/bin/env bash
# Rsync the working tree to a remote server's /data/newapi (configurable).
#
# Usage:
#   ./scripts/sync.sh <host> [flags]
#
# Positional argument:
#   <host>             Required. SSH target. Either "user@host" or just "host".
#
# Flags:
#   --path  <path>     Remote target directory. Default: /data/newapi
#   --port  <port>     SSH port. Default: 22
#   --key   <file>     Path to an SSH private key.
#   --user  <user>     SSH user when <host> has no "user@" prefix.
#   --rsync-extra <s>  Extra rsync flags appended verbatim.
#   --dry-run          Show what would change; transfer nothing.
#   --delete           Mirror mode: remove files on the remote that don't exist
#                      locally. Excluded paths (data/, .env, certs, ...) are
#                      protected by rsync's exclude semantics, so host state is
#                      not wiped. Off by default — opt in explicitly.
#   -h | --help        Show usage.
#
# Examples:
#   ./scripts/sync.sh deploy@prod-1.example.com
#   ./scripts/sync.sh 1.2.3.4 --user root --port 2222 --key ~/.ssh/id_ed25519
#   ./scripts/sync.sh prod.example.com --dry-run --delete
#
# After syncing, run the deploy/upgrade script on the remote, e.g.:
#   ssh <host> 'cd /data/newapi && ./scripts/deploy.sh'

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf "[sync] %s\n" "$*"; }
die() { printf "[sync] %s\n" "$*" >&2; exit 1; }

usage() {
    awk '
        NR == 1 { next }            # skip shebang
        /^#/    { sub(/^# ?/, ""); print; next }
        { exit }                    # stop at first non-comment line
    ' "${BASH_SOURCE[0]}"
}

REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PATH="/data/newapi"
SSH_PORT="22"
SSH_KEY=""
RSYNC_EXTRA=""
DRY_RUN=0
DELETE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)         REMOTE_PATH="${2:?--path needs a value}"; shift 2 ;;
        --port)         SSH_PORT="${2:?--port needs a value}"; shift 2 ;;
        --key)          SSH_KEY="${2:?--key needs a value}"; shift 2 ;;
        --user)         REMOTE_USER="${2:?--user needs a value}"; shift 2 ;;
        --rsync-extra)  RSYNC_EXTRA="${2:?--rsync-extra needs a value}"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --delete)       DELETE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             die "unknown flag: $1 (use --help)" ;;
        *)
            [[ -n "$REMOTE_HOST" ]] && die "unexpected extra argument: $1"
            REMOTE_HOST="$1"
            shift
            ;;
    esac
done

[[ -n "$REMOTE_HOST" ]] || { usage; echo; die "missing required <host> argument."; }

command -v rsync >/dev/null 2>&1 || die "rsync is required."

if [[ "$REMOTE_HOST" != *"@"* && -n "$REMOTE_USER" ]]; then
    REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
else
    REMOTE_TARGET="$REMOTE_HOST"
fi

SSH_CMD=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || die "ssh key not found: $SSH_KEY"
    SSH_CMD+=(-i "$SSH_KEY")
fi

# Make sure the remote directory exists before rsyncing into it.
log "ensuring ${REMOTE_TARGET}:${REMOTE_PATH} exists..."
"${SSH_CMD[@]}" "$REMOTE_TARGET" "mkdir -p '$REMOTE_PATH'"

# Excludes — keep this list aligned with .gitignore plus a few transfer-only
# safety nets. Excluded paths are also protected from --delete on the remote.
EXCLUDES=(
    --exclude='.git/'
    --exclude='.github/'
    --exclude='.env'
    --exclude='.env.local'
    --exclude='.env.*.local'
    --exclude='data/'
    --exclude='logs/'
    --exclude='upload/'
    --exclude='nginx/certs/'
    --exclude='nginx/www/'
    --exclude='nginx/conf.d/new-api.conf'
    --exclude='*.pem'
    --exclude='*.key'
    --exclude='*.db'
    --exclude='*.db-journal'
    --exclude='*.exe'
    --exclude='/new-api'
    --exclude='/one-api'
    --exclude='__debug_bin*'
    --exclude='.DS_Store'
    --exclude='.idea/'
    --exclude='.vscode/'
    --exclude='.zed/'
    --exclude='.history/'
    --exclude='.cursor/'
    --exclude='.claude/'
    --exclude='node_modules/'
    --exclude='web/default/dist/'
    --exclude='web/classic/dist/'
    --exclude='web/dist/'
    --exclude='electron/node_modules/'
    --exclude='electron/dist/'
    --exclude='.cache/'
    --exclude='.eslintcache'
    --exclude='.gocache/'
    --exclude='.gocache-temp/'
    --exclude='.gomodcache/'
    --exclude='.gopath/'
    --exclude='tiktoken_cache/'
    --exclude='plans/'
    --exclude='.test/'
)

# Flag set chosen to work on both GNU rsync (Linux/Homebrew) and the openrsync
# implementation shipped with macOS. Avoid --info=*, --human-readable, etc.
RSYNC_ARGS=(
    -avz
    --partial
    --stats
    -e "${SSH_CMD[*]}"
)
[[ $DRY_RUN -eq 1 ]] && RSYNC_ARGS+=(--dry-run)
[[ $DELETE  -eq 1 ]] && RSYNC_ARGS+=(--delete)

# shellcheck disable=SC2206
[[ -n "$RSYNC_EXTRA" ]] && RSYNC_ARGS+=( ${RSYNC_EXTRA} )

log "syncing $REPO_ROOT/  -->  ${REMOTE_TARGET}:${REMOTE_PATH}/"
[[ $DRY_RUN -eq 1 ]] && log "(dry-run; no files will be transferred)"
[[ $DELETE  -eq 1 ]] && log "(--delete enabled; remote-only files will be removed, excluded paths are preserved)"

rsync "${RSYNC_ARGS[@]}" "${EXCLUDES[@]}" ./ "${REMOTE_TARGET}:${REMOTE_PATH}/"

log "done. Next step on the remote:"
log "  ssh ${REMOTE_TARGET} 'cd ${REMOTE_PATH} && ./scripts/deploy.sh'   # first time"
log "  ssh ${REMOTE_TARGET} 'cd ${REMOTE_PATH} && ./scripts/upgrade.sh'  # subsequent rolls"
