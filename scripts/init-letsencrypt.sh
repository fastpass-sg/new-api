#!/usr/bin/env bash
# Bootstrap Let's Encrypt certificates for the domains this stack serves.
#
# One certificate per domain rather than a single multi-SAN certificate: each
# nginx server block then points at a path named after its own domain, and
# adding or removing a domain never re-issues the others.
#
# Approach (based on the official nginx-certbot recipe):
#   1. Drop a 1-day self-signed cert at each path nginx expects, so nginx can
#      come up on :443 before any real cert exists.
#   2. Start nginx so it can serve the http-01 challenge from /var/www/certbot.
#   3. Per domain: clear the placeholder and run certbot certonly --webroot.
#   4. Reload nginx so it picks up the real certs.
#
# Only touches the domains it is asked to handle. Domains governed by a `byo`
# certificate mode are never cleared, so a hand-installed certificate on the
# main site cannot be destroyed by bootstrapping the Logto domains.
#
# Usage:
#   ./scripts/init-letsencrypt.sh                    # every letsencrypt-mode domain
#   ./scripts/init-letsencrypt.sh auth.example.com   # just this one
#
# Flags:
#   --staging   Use Let's Encrypt staging environment (avoid rate limits).
#   --force     Issue even for domains whose cert mode is `byo`. Destructive:
#               replaces any certificate already installed for them.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_PREFIX=init-letsencrypt
# shellcheck source=scripts/_lib.sh
. "$REPO_ROOT/scripts/_lib.sh"

STAGING_ARG=""
FORCE=0
REQUESTED_DOMAINS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging) STAGING_ARG="--staging"; shift ;;
        --force)   FORCE=1; shift ;;
        -*)        die "unknown flag: $1" ;;
        *)         REQUESTED_DOMAINS+=("$1"); shift ;;
    esac
done

load_env
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set in .env}"

# Resolve the work list: explicit arguments, else whatever .env puts under
# Let's Encrypt management.
TARGETS=()
if [[ ${#REQUESTED_DOMAINS[@]} -gt 0 ]]; then
    TARGETS=("${REQUESTED_DOMAINS[@]}")
else
    while read -r d; do
        [[ -n "$d" ]] && TARGETS+=("$d")
    done < <(letsencrypt_domains)
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    cat >&2 <<EOF
[init-letsencrypt] nothing to do.
  CERT_MODE=$CERT_MODE governs $DOMAIN_NAME
  LOGTO_ENABLED=$LOGTO_ENABLED, LOGTO_CERT_MODE=$LOGTO_CERT_MODE governs the Logto domains
  No domain is set to 'letsencrypt'. Set one in .env, or name a domain explicitly.
EOF
    exit 3
fi

# Refuse to overwrite a certificate the operator installed themselves.
managed="$(letsencrypt_domains | tr '\n' ' ')"
for domain in "${TARGETS[@]}"; do
    if [[ " $managed " != *" $domain "* && $FORCE -eq 0 ]]; then
        die "refusing to issue for $domain: its cert mode is 'byo' in .env.
  Switch it to 'letsencrypt' there, or pass --force to overwrite the existing
  certificate at $(cert_dir "$domain")."
    fi
done

log "target domains: ${TARGETS[*]}"

# nginx must be able to start before it can serve the ACME challenge, and it
# only starts if every rendered server block finds a certificate.
render_nginx_configs
mkdir -p "$DATA_ROOT/nginx/www"

PENDING=()
for domain in "${TARGETS[@]}"; do
    if [[ -s "$(cert_file "$domain")" ]] && is_letsencrypt_cert "$(cert_file "$domain")"; then
        log "$domain already has a Let's Encrypt cert; skipping."
        continue
    fi
    PENDING+=("$domain")
done

if [[ ${#PENDING[@]} -eq 0 ]]; then
    log "all target domains already hold Let's Encrypt certs, nothing to do."
    exit 0
fi

write_placeholder_cert() {
    local domain="$1" dir
    dir="$(cert_dir "$domain")"
    mkdir -p "$dir"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout "$dir/privkey.pem" \
        -out "$dir/fullchain.pem" \
        -subj "/CN=${domain}" >/dev/null 2>&1
}

for domain in "${PENDING[@]}"; do
    log "writing 1-day self-signed placeholder cert for $domain..."
    write_placeholder_cert "$domain"
done

build_compose_cmd

log "starting nginx with placeholder cert(s)..."
"${COMPOSE[@]}" up -d nginx

for domain in "${PENDING[@]}"; do
    log "requesting certificate for $domain..."
    # certbot --webroot fails when live/<domain> already holds files it did not
    # create, so the placeholder has to go first. If issuance then fails we put a
    # placeholder back, otherwise nginx would refuse to start on the next reload.
    rm -rf "$(cert_dir "$domain")"

    if ! "${COMPOSE[@]}" run --rm --entrypoint "" certbot \
            certbot certonly \
                --webroot -w /var/www/certbot \
                -d "$domain" \
                --email "${CERTBOT_EMAIL}" \
                --agree-tos --no-eff-email \
                --non-interactive \
                ${STAGING_ARG}; then
        warn "certbot failed for $domain; restoring a placeholder so nginx stays startable."
        write_placeholder_cert "$domain"
        die "could not issue a certificate for $domain. Check that it resolves to this host and that port 80 is reachable."
    fi

    log "issued certificate for $domain."
done

log "reloading nginx..."
"${COMPOSE[@]}" exec nginx nginx -s reload

log "done — the following now serve valid certificates:"
for domain in "${PENDING[@]}"; do
    log "  https://${domain}"
done
