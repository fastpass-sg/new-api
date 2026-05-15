#!/usr/bin/env bash
# Bootstrap Let's Encrypt certificates for ${DOMAIN_NAME}.
#
# Approach (based on the official nginx-certbot recipe):
#   1. Drop a 1-day self-signed cert at the path nginx expects, so nginx can
#      come up on :443 even though we don't have a real cert yet.
#   2. Start nginx so it can serve the http-01 challenge from /var/www/certbot.
#   3. Delete the dummy cert and run certbot certonly --webroot to fetch a real
#      cert from Let's Encrypt.
#   4. Reload nginx so it picks up the real cert.
#
# Flags:
#   --staging   Use Let's Encrypt staging environment (avoid rate limits).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f .env ]]; then
    echo "[init-letsencrypt] .env missing; run scripts/gen-env.sh first." >&2
    exit 1
fi

# Load .env without exporting comments / blanks.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set in .env}"

STAGING_ARG=""
for arg in "$@"; do
    case "$arg" in
        --staging) STAGING_ARG="--staging" ;;
        *) echo "[init-letsencrypt] unknown flag: $arg" >&2; exit 2 ;;
    esac
done

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)

CERT_DIR="nginx/certs/live/${DOMAIN_NAME}"
mkdir -p "$CERT_DIR" nginx/www

if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]]; then
    # Detect placeholder vs real cert by issuer.
    if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer 2>/dev/null | grep -qi "let's encrypt"; then
        echo "[init-letsencrypt] real Let's Encrypt cert already present, nothing to do."
        exit 0
    fi
fi

echo "[init-letsencrypt] writing 1-day self-signed placeholder cert..."
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=${DOMAIN_NAME}" >/dev/null 2>&1

echo "[init-letsencrypt] starting nginx with placeholder cert..."
"${COMPOSE[@]}" up -d nginx

echo "[init-letsencrypt] removing placeholder and requesting real cert..."
# certbot needs a clean live dir, otherwise --webroot fails with "expected directory".
rm -rf "$CERT_DIR"

"${COMPOSE[@]}" run --rm --entrypoint "" certbot \
    certbot certonly \
        --webroot -w /var/www/certbot \
        -d "${DOMAIN_NAME}" \
        --email "${CERTBOT_EMAIL}" \
        --agree-tos --no-eff-email \
        --non-interactive \
        ${STAGING_ARG}

echo "[init-letsencrypt] reloading nginx..."
"${COMPOSE[@]}" exec nginx nginx -s reload

echo "[init-letsencrypt] done — https://${DOMAIN_NAME} should now serve a valid certificate."
