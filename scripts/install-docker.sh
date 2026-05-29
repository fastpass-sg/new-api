#!/usr/bin/env bash
# Install Docker (Engine + Compose v2) on a Linux server.
#
# Default behavior:
#   1. Install Docker Engine via the official get.docker.com convenience script
#      (covers Debian/Ubuntu/RHEL/CentOS/Rocky/Alma/Fedora/SUSE/Raspbian).
#      That script also installs the docker-compose-plugin package on most
#      modern distros, so step 2 is usually a no-op.
#   2. If `docker compose` still doesn't work, drop the official CLI plugin
#      binary from https://github.com/docker/compose/releases into the
#      directory the docker CLI scans for plugins.
#   3. Start and enable the docker systemd unit (when systemd is present).
#   4. Add the invoking user (or --add-user <name>) to the docker group, so
#      they can run docker without sudo. Takes effect after re-login.
#
# Usage:
#   ./scripts/install-docker.sh [flags]
#
# Flags:
#   --engine-only            Install Docker Engine only; skip compose checks.
#   --compose-only           Install/verify Docker Compose v2 only; skip engine.
#   --skip-engine            Don't touch engine even if it's missing.
#   --skip-compose           Don't install or verify compose.
#   --skip-user-group        Don't touch the docker group.
#   --add-user <name>        Add this user to the docker group (default: $USER
#                            or $SUDO_USER when running via sudo).
#   --compose-version <ver>  Pin a docker compose v2 tag (e.g. v2.29.7).
#                            Default: query GitHub for the latest release.
#   --force                  Reinstall compose binary even if already present.
#   -h | --help              Show this help.
#
# Examples:
#   sudo ./scripts/install-docker.sh                       # one-shot full setup
#   sudo ./scripts/install-docker.sh --add-user deploy     # add a different user
#   ./scripts/install-docker.sh --compose-only --user      # user-level compose only
#   sudo ./scripts/install-docker.sh --compose-version v2.29.7
#   ssh newapi 'sudo bash -s' < scripts/install-docker.sh
#
# Notes:
#   - Docker's get.docker.com script needs root. The script will use sudo when
#     not invoked as root; sudo is required in that case.
#   - This script does NOT install Docker Desktop. On macOS use Docker Desktop
#     manually; this script is Linux only.

set -euo pipefail

COMPOSE_REPO="docker/compose"

log()  { printf "[install-docker] %s\n" "$*"; }
warn() { printf "[install-docker] WARN: %s\n" "$*" >&2; }
die()  { printf "[install-docker] %s\n" "$*" >&2; exit 1; }

usage() {
    awk '
        NR == 1 { next }
        /^#/    { sub(/^# ?/, ""); print; next }
        { exit }
    ' "${BASH_SOURCE[0]}"
}

# ----- flag parsing ---------------------------------------------------------
ENGINE_ONLY=0
COMPOSE_ONLY=0
SKIP_ENGINE=0
SKIP_COMPOSE=0
SKIP_USER_GROUP=0
ADD_USER=""
COMPOSE_VERSION=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine-only)        ENGINE_ONLY=1; shift ;;
        --compose-only)       COMPOSE_ONLY=1; shift ;;
        --skip-engine)        SKIP_ENGINE=1; shift ;;
        --skip-compose)       SKIP_COMPOSE=1; shift ;;
        --skip-user-group)    SKIP_USER_GROUP=1; shift ;;
        --add-user)           ADD_USER="${2:?--add-user needs a value}"; shift 2 ;;
        --compose-version)    COMPOSE_VERSION="${2:?--compose-version needs a value}"; shift 2 ;;
        --force)              FORCE=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) die "unknown flag: $1 (use --help)" ;;
    esac
done

[[ $ENGINE_ONLY -eq 1 && $COMPOSE_ONLY -eq 1 ]] \
    && die "--engine-only and --compose-only are mutually exclusive."
[[ $ENGINE_ONLY -eq 1 ]]  && SKIP_COMPOSE=1
[[ $COMPOSE_ONLY -eq 1 ]] && SKIP_ENGINE=1

# ----- platform check -------------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
[[ "$OS" == "linux" ]] || die "this script supports Linux only (detected: $OS)."

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)   ASSET_ARCH="x86_64" ;;
    aarch64|arm64)  ASSET_ARCH="aarch64" ;;
    armv7l|armv7)   ASSET_ARCH="armv7" ;;
    *) die "unsupported arch: $ARCH" ;;
esac

# ----- sudo helper ----------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "running non-root and 'sudo' not found."
    SUDO="sudo"
fi

# ----- step 1: Docker Engine ------------------------------------------------
install_engine() {
    if command -v docker >/dev/null 2>&1; then
        log "docker engine already installed: $(docker --version 2>/dev/null || echo unknown)"
        return 0
    fi

    log "installing Docker Engine via https://get.docker.com ..."
    command -v curl >/dev/null 2>&1 || die "curl is required to install Docker Engine."

    # Pipe the official convenience script to sh. It detects the distro and
    # installs docker-ce, containerd, buildx-plugin, and compose-plugin.
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    $SUDO sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    command -v docker >/dev/null 2>&1 \
        || die "Docker Engine install reported success but 'docker' is still not on PATH."

    if command -v systemctl >/dev/null 2>&1; then
        log "enabling and starting docker.service ..."
        $SUDO systemctl enable --now docker || warn "could not enable docker.service via systemctl."
    else
        warn "systemd not detected; start the docker daemon manually."
    fi
}

# ----- step 2: Docker Compose v2 -------------------------------------------
install_compose_binary() {
    log "installing docker compose v2 binary from GitHub..."

    if [[ -z "$COMPOSE_VERSION" ]]; then
        log "querying latest release tag from GitHub..."
        if command -v curl >/dev/null 2>&1; then
            COMPOSE_VERSION="$(curl -fsSL "https://api.github.com/repos/${COMPOSE_REPO}/releases/latest" \
                | grep -oE '"tag_name": *"v[^"]+"' \
                | head -1 \
                | sed -E 's/.*"(v[^"]+)".*/\1/')"
        elif command -v wget >/dev/null 2>&1; then
            COMPOSE_VERSION="$(wget -qO- "https://api.github.com/repos/${COMPOSE_REPO}/releases/latest" \
                | grep -oE '"tag_name": *"v[^"]+"' \
                | head -1 \
                | sed -E 's/.*"(v[^"]+)".*/\1/')"
        fi
        [[ -n "$COMPOSE_VERSION" ]] || die "couldn't auto-detect latest compose version (GitHub rate-limited?). Pass --compose-version vX.Y.Z."
    fi

    local url="https://github.com/${COMPOSE_REPO}/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ASSET_ARCH}"
    local target_dir="/usr/local/lib/docker/cli-plugins"
    local target_file="$target_dir/docker-compose"
    local tmp
    tmp="$(mktemp)"

    log "downloading $url ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 "$url" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
    else
        rm -f "$tmp"
        die "neither curl nor wget available."
    fi

    local file_size
    file_size=$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)
    if [[ "$file_size" -lt 1000000 ]]; then
        rm -f "$tmp"
        die "downloaded binary is suspiciously small ($file_size bytes); URL may have 404'd."
    fi

    $SUDO mkdir -p "$target_dir"
    $SUDO install -m 0755 "$tmp" "$target_file"
    rm -f "$tmp"

    log "compose binary placed at $target_file"
}

ensure_compose() {
    if docker compose version >/dev/null 2>&1 && [[ $FORCE -eq 0 ]]; then
        log "docker compose already works: $(docker compose version --short 2>/dev/null || echo unknown)"
        return 0
    fi
    install_compose_binary
    docker compose version >/dev/null 2>&1 \
        || die "compose binary installed but 'docker compose' still fails. Check PATH and docker version."
    log "ok — docker compose v$(docker compose version --short 2>/dev/null || echo unknown) ready."
}

# ----- step 3: docker group -------------------------------------------------
ensure_user_in_docker_group() {
    local user="${ADD_USER:-${SUDO_USER:-$USER}}"
    [[ -n "$user" && "$user" != "root" ]] || { log "skipping docker group setup (user='$user')."; return 0; }

    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log "user '$user' is already in the docker group."
        return 0
    fi

    log "adding user '$user' to the docker group (re-login required to take effect)..."
    $SUDO groupadd -f docker
    $SUDO usermod -aG docker "$user"
}

# ----- main -----------------------------------------------------------------
if [[ $SKIP_ENGINE -ne 1 ]]; then
    install_engine
else
    log "skipping engine install (--skip-engine or --compose-only)."
fi

if [[ $SKIP_COMPOSE -ne 1 ]]; then
    command -v docker >/dev/null 2>&1 \
        || die "docker engine is not installed; rerun without --compose-only or install it first."
    ensure_compose
else
    log "skipping compose install (--skip-compose or --engine-only)."
fi

if [[ $SKIP_USER_GROUP -ne 1 && $SKIP_ENGINE -ne 1 ]]; then
    ensure_user_in_docker_group
fi

log "done."
log "summary:"
command -v docker >/dev/null 2>&1 && log "  $(docker --version)"
docker compose version >/dev/null 2>&1 && log "  $(docker compose version)"

if [[ $SKIP_USER_GROUP -ne 1 && $SKIP_ENGINE -ne 1 ]]; then
    log "note: if you were added to the docker group, log out + back in (or run 'newgrp docker') before docker commands work without sudo."
fi
