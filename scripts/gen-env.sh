#!/usr/bin/env bash
# Generate a .env from .env.example with strong random secrets.
# Idempotent: if .env already exists, leaves it untouched.
#
# Single sign-on stays off in a freshly generated .env. Enabling it is a
# deliberate second step — see docs/deploy/logto-sso.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE=".env"
TEMPLATE=".env.example"

if [[ -f "$ENV_FILE" ]]; then
    echo "[gen-env] $ENV_FILE already exists; leaving it as-is."
    exit 0
fi

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[gen-env] $TEMPLATE not found — cannot generate $ENV_FILE." >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "[gen-env] openssl is required but not installed." >&2
    exit 1
fi

cp "$TEMPLATE" "$ENV_FILE"

rand() { openssl rand -hex 32; }

# macOS / BSD sed and GNU sed differ on -i; use a portable awk rewrite.
set_value() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        BEGIN { FS=OFS="=" }
        $1 == k { print k"="v; next }
        { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# Only fills empty `KEY=` lines, so a value already present is never clobbered.
fill_blank() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        BEGIN { FS=OFS="=" }
        $0 ~ "^"k"=$" { print k"="v; next }
        { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

fill_blank "POSTGRES_PASSWORD"  "$(rand)"
fill_blank "REDIS_PASSWORD"     "$(rand)"
fill_blank "SESSION_SECRET"     "$(rand)"
# Generated up front so enabling Logto later needs no secret wrangling. Hex, so
# it never needs URL escaping inside DB_URL.
fill_blank "LOGTO_DB_PASSWORD"  "$(rand)"
# CRYPTO_SECRET intentionally left blank — backend falls back to SESSION_SECRET.

# Prompt for DOMAIN_NAME / CERTBOT_EMAIL unless already provided via env.
prompt_replace() {
    local key="$1"
    local prompt="$2"
    local current
    current="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" || true)"
    local fromenv="${!key-}"
    local value="${fromenv:-}"
    if [[ -z "$value" && ( -z "$current" || "$current" == "example.com" || "$current" == "admin@example.com" ) ]]; then
        read -rp "$prompt " value
    fi
    if [[ -n "$value" ]]; then
        set_value "$key" "$value"
    fi
}

prompt_replace "DOMAIN_NAME"   "Public domain for HTTPS (e.g. api.example.com):"
prompt_replace "CERTBOT_EMAIL" "Email for Let's Encrypt notifications:"

# New deployments are HTTPS-only from the first boot, so Secure cookies and
# strict OriginGuard can be on from the start. Deriving the trusted origin from
# the domain just entered removes the only way this pair gets misconfigured.
DOMAIN_NAME_VALUE="$(awk -F= '$1=="DOMAIN_NAME" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE")"
if [[ -n "$DOMAIN_NAME_VALUE" && "$DOMAIN_NAME_VALUE" != "example.com" ]]; then
    set_value "SESSION_COOKIE_SECURE"       "true"
    set_value "SESSION_COOKIE_TRUSTED_URL"  "https://${DOMAIN_NAME_VALUE}"
    echo "[gen-env] enabled Secure session cookies for https://${DOMAIN_NAME_VALUE}"
fi

chmod 600 "$ENV_FILE"
echo "[gen-env] wrote $ENV_FILE (mode 600). Review before deploying."
