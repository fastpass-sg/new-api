# shellcheck shell=bash
# Shared helpers for deploy.sh, upgrade.sh and init-letsencrypt.sh.
#
# Not executable on its own. Source it after setting LOG_PREFIX:
#   LOG_PREFIX=deploy
#   . "$REPO_ROOT/scripts/_lib.sh"
#
# Everything here is deliberately side-effect free until called, so
# init-letsencrypt.sh can reuse the certificate helpers without triggering the
# nginx rendering that only the deploy path wants.

LOG_PREFIX="${LOG_PREFIX:-newapi}"

log()  { printf "[%s] %s\n" "$LOG_PREFIX" "$*"; }
warn() { printf "[%s] WARN: %s\n" "$LOG_PREFIX" "$*" >&2; }
die()  { printf "[%s] %s\n" "$LOG_PREFIX" "$*" >&2; exit 1; }

# Loads .env and applies the defaults every script assumes. Validates the two
# certificate mode knobs here so a typo fails before anything is touched.
load_env() {
    [[ -f .env ]] || die ".env missing — run scripts/gen-env.sh (or scripts/deploy.sh) first."

    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a

    : "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"

    DATA_ROOT="${DATA_ROOT:-/data/newapi_data}"
    CERT_MODE="${CERT_MODE:-byo}"
    LOGTO_ENABLED="${LOGTO_ENABLED:-false}"
    LOGTO_CERT_MODE="${LOGTO_CERT_MODE:-letsencrypt}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

    case "$CERT_MODE" in
        byo|letsencrypt) ;;
        *) die "CERT_MODE must be 'byo' or 'letsencrypt' (got: $CERT_MODE)" ;;
    esac
    case "$LOGTO_CERT_MODE" in
        byo|letsencrypt) ;;
        *) die "LOGTO_CERT_MODE must be 'byo' or 'letsencrypt' (got: $LOGTO_CERT_MODE)" ;;
    esac

    if logto_enabled; then
        : "${LOGTO_DOMAIN:?LOGTO_DOMAIN must be set in .env when LOGTO_ENABLED=true}"
        : "${LOGTO_ADMIN_DOMAIN:?LOGTO_ADMIN_DOMAIN must be set in .env when LOGTO_ENABLED=true}"
        : "${LOGTO_DB_PASSWORD:?LOGTO_DB_PASSWORD must be set in .env when LOGTO_ENABLED=true}"
        LOGTO_DB_NAME="${LOGTO_DB_NAME:-logto}"
        LOGTO_DB_USER="${LOGTO_DB_USER:-logto}"
        if [[ "$LOGTO_DOMAIN" == "$LOGTO_ADMIN_DOMAIN" ]]; then
            die "LOGTO_DOMAIN and LOGTO_ADMIN_DOMAIN must differ; Logto serves them from different ports."
        fi
        if [[ "$LOGTO_DOMAIN" == "$DOMAIN_NAME" || "$LOGTO_ADMIN_DOMAIN" == "$DOMAIN_NAME" ]]; then
            die "Logto domains must differ from DOMAIN_NAME ($DOMAIN_NAME)."
        fi
    fi

    # The fallback itself lives in docker-compose.prod.yml so that a plain
    # `docker compose up` also produces a startable container. This only reports
    # what will be used, since a silent origin is the setting people get wrong.
    if [[ "${SESSION_COOKIE_SECURE:-false}" == "true" && -z "${SESSION_COOKIE_TRUSTED_URL:-}" ]]; then
        log "SESSION_COOKIE_TRUSTED_URL is empty; compose will default it to https://${DOMAIN_NAME}"
    fi
}

logto_enabled() {
    [[ "${LOGTO_ENABLED:-false}" == "true" ]]
}

cert_dir()  { printf '%s/nginx/certs/live/%s' "$DATA_ROOT" "$1"; }
cert_file() { printf '%s/fullchain.pem' "$(cert_dir "$1")"; }
key_file()  { printf '%s/privkey.pem' "$(cert_dir "$1")"; }

# Every domain nginx will serve, in the order server blocks are rendered.
served_domains() {
    printf '%s\n' "$DOMAIN_NAME"
    if logto_enabled; then
        printf '%s\n%s\n' "$LOGTO_DOMAIN" "$LOGTO_ADMIN_DOMAIN"
    fi
}

# The subset whose certificates Let's Encrypt is responsible for. CERT_MODE
# governs the main domain; LOGTO_CERT_MODE governs the Logto domains. Keeping
# them separate is what lets the main site keep a BYO certificate while the new
# Logto domains are issued automatically.
letsencrypt_domains() {
    [[ "$CERT_MODE" == "letsencrypt" ]] && printf '%s\n' "$DOMAIN_NAME"
    if logto_enabled && [[ "$LOGTO_CERT_MODE" == "letsencrypt" ]]; then
        printf '%s\n%s\n' "$LOGTO_DOMAIN" "$LOGTO_ADMIN_DOMAIN"
    fi
    return 0
}

any_letsencrypt() {
    [[ -n "$(letsencrypt_domains)" ]]
}

# True when the certificate at this path was actually issued by Let's Encrypt,
# as opposed to a BYO certificate or one of our self-signed placeholders.
is_letsencrypt_cert() {
    openssl x509 -in "$1" -noout -issuer 2>/dev/null | grep -qi "let's encrypt"
}

# Warns under 30 days, refuses to continue under 7. Renewal is automatic for
# Let's Encrypt domains, so in practice this fires for BYO certificates.
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
        die "TLS cert at $cert expires in $days_left day(s) ($end_date). Renew it before continuing."
    elif [[ $days_left -lt 30 ]]; then
        warn "TLS cert at $cert expires in $days_left day(s) ($end_date). Plan a renewal."
    else
        log "TLS cert for $(basename "$(dirname "$cert")") OK — $days_left day(s) remaining."
    fi
}

# nginx will not start if a rendered server block points at a certificate that
# is not there, so this is a hard failure rather than a warning.
require_byo_certs() {
    local domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        case " $(letsencrypt_domains | tr '\n' ' ') " in
            *" $domain "*) continue ;;   # issued automatically, not BYO
        esac
        if [[ ! -s "$(cert_file "$domain")" || ! -s "$(key_file "$domain")" ]]; then
            die "no certificate for $domain. Place your files at:
    $(cert_file "$domain")
    $(key_file "$domain")
then re-run this script. (Or switch that domain to Let's Encrypt in .env.)"
        fi
        check_cert_expiry "$(cert_file "$domain")" || true
    done < <(served_domains)
}

# Renders every nginx server block from its template, and removes the Logto
# blocks when Logto is off so a disabled container can never leave nginx
# pointing at an upstream host that does not resolve.
render_nginx_configs() {
    command -v envsubst >/dev/null 2>&1 || die "envsubst is required (install gettext-base / gettext)."

    log "rendering nginx config for ${DOMAIN_NAME}..."
    envsubst '${DOMAIN_NAME}' \
        < nginx/conf.d/new-api.conf.template \
        > nginx/conf.d/new-api.conf

    if ! logto_enabled; then
        rm -f nginx/conf.d/logto.conf nginx/conf.d/logto-admin.conf
        return 0
    fi

    log "rendering nginx config for ${LOGTO_DOMAIN} and ${LOGTO_ADMIN_DOMAIN}..."
    envsubst '${LOGTO_DOMAIN}' \
        < nginx/conf.d/logto.conf.template \
        > nginx/conf.d/logto.conf

    # Turn the space-separated allowlist into nginx directives. Empty means no
    # IP restriction, so the placeholder renders to nothing at all.
    LOGTO_ADMIN_ALLOW_BLOCK=""
    if [[ -n "${LOGTO_ADMIN_ALLOW:-}" ]]; then
        local entry
        for entry in $LOGTO_ADMIN_ALLOW; do
            LOGTO_ADMIN_ALLOW_BLOCK+="    allow ${entry};"$'\n'
        done
        LOGTO_ADMIN_ALLOW_BLOCK+="    deny all;"
        log "admin console restricted to: $LOGTO_ADMIN_ALLOW"
    else
        warn "LOGTO_ADMIN_ALLOW is empty — the Logto admin console is reachable from any IP (Logto's own login still applies)."
    fi
    export LOGTO_ADMIN_ALLOW_BLOCK

    envsubst '${LOGTO_ADMIN_DOMAIN} ${LOGTO_ADMIN_ALLOW_BLOCK}' \
        < nginx/conf.d/logto-admin.conf.template \
        > nginx/conf.d/logto-admin.conf
}

nginx_is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' new-api-nginx 2>/dev/null)" == "true" ]]
}

# A bad render leaves nginx unable to start, which takes the whole site down.
# Testing inside the running container is the only check that sees the real
# certificates and can resolve the upstream hostnames on the compose network.
# When nginx is not running yet there is nothing to protect, so this is a no-op.
verify_nginx_config() {
    if ! nginx_is_running; then
        log "nginx is not running yet; its config will be validated when it starts."
        return 0
    fi
    log "validating nginx config..."
    if ! "${COMPOSE[@]}" exec -T nginx nginx -t; then
        die "nginx rejected the rendered config (see the output above). Nothing was restarted; the running site is untouched."
    fi
}

# The conf.d bind mount means a re-render is visible inside the container
# immediately, but nginx only reads it on reload. Without this an nginx-only
# change would sit unapplied until the container's 6-hourly reload loop, because
# `up -d` recreates a container only when its compose definition changes.
reload_nginx() {
    nginx_is_running || return 0
    log "reloading nginx to apply the rendered config..."
    "${COMPOSE[@]}" exec -T nginx nginx -s reload \
        || warn "nginx reload failed; the previous config is still live."
}

# Builds the compose invocation into the COMPOSE array, enabling the profiles
# the current .env asks for.
build_compose_cmd() {
    COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env)
    if any_letsencrypt; then
        COMPOSE+=(--profile letsencrypt)
    fi
    if logto_enabled; then
        COMPOSE+=(--profile logto)
    fi
}
