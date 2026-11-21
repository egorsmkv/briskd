#!/bin/sh
# Obtain and renew the IRC server's TLS certificate with lego (ACME), and
# publish it for briskd. Runs in the goacme/lego image (docker-compose.lego.yml).
#
# lego reads its own settings from the environment (lego.env):
#   LEGO_DOMAINS, LEGO_EMAIL, LEGO_ACCEPT_TOS=true      required
#   LEGO_SERVER         CA, default Let's Encrypt; use letsencrypt-staging first
#   LEGO_HTTP=true      HTTP-01 on port 80 (default when no challenge is set)
#   LEGO_TLS=true       TLS-ALPN-01 on port 443
#   LEGO_DNS=<provider> DNS-01, plus that provider's credentials (lego dnshelp)
#   LEGO_KEY_TYPE       default EC256
# and this script's:
#   CHECK_INTERVAL      seconds between renewal checks (default 43200, 12 h)
#   RETRY_INTERVAL      seconds before retrying a failed run (default 3600)
#   BRISKD_UID, BRISKD_GID  owner of the published key (default 10001, Dockerfile.prod)
#
# `lego run` obtains the certificate the first time and renews it when it is
# due (ARI or one third of its lifetime left); otherwise it changes nothing.
# After each successful run the certificate and key are copied to /certs as
# fullchain.pem (0644) and privkey.pem (0640, owned by briskd). Each file is
# written to a temporary name and renamed, so briskd never reads half a file;
# briskd_certs reloads them within tls_reload_interval seconds. A failed
# publish is retried like a failed `lego run`.
set -eu

: "${LEGO_DOMAINS:?set LEGO_DOMAINS in lego.env}"
: "${LEGO_EMAIL:?set LEGO_EMAIL in lego.env}"
if [ "${LEGO_ACCEPT_TOS:-}" != "true" ]; then
    echo "lego.sh: set LEGO_ACCEPT_TOS=true in lego.env to accept the CA's terms of service" >&2
    exit 1
fi
if [ -z "${LEGO_HTTP:-}${LEGO_TLS:-}${LEGO_DNS:-}" ]; then
    export LEGO_HTTP=true
fi

export LEGO_PATH=/data
export LEGO_CERT_NAME=briskd
CERT="$LEGO_PATH/certificates/briskd.crt"
KEY="$LEGO_PATH/certificates/briskd.key"
OUT=/certs
CHECK_INTERVAL="${CHECK_INTERVAL:-43200}"
RETRY_INTERVAL="${RETRY_INTERVAL:-3600}"
BRISKD_UID="${BRISKD_UID:-10001}"
BRISKD_GID="${BRISKD_GID:-10001}"
positive_int() {
    case $2 in
        '' | *[!0-9]* | 0)
            echo "lego.sh: $1 must be a positive integer" >&2
            exit 1
            ;;
    esac
}
positive_int CHECK_INTERVAL "$CHECK_INTERVAL"
positive_int RETRY_INTERVAL "$RETRY_INTERVAL"
positive_int BRISKD_UID "$BRISKD_UID"
positive_int BRISKD_GID "$BRISKD_GID"

publish() {
    install -m 0640 -o "$BRISKD_UID" -g "$BRISKD_GID" "$KEY" "$OUT/.privkey.pem.tmp"
    install -m 0644 -o "$BRISKD_UID" -g "$BRISKD_GID" "$CERT" "$OUT/.fullchain.pem.tmp"
    mv -f "$OUT/.privkey.pem.tmp" "$OUT/privkey.pem"
    mv -f "$OUT/.fullchain.pem.tmp" "$OUT/fullchain.pem"
}

mkdir -p "$OUT"
while true; do
    if /lego run && publish; then
        echo "lego.sh: certificate for $LEGO_DOMAINS published; next check in ${CHECK_INTERVAL}s"
        sleep "$CHECK_INTERVAL"
    else
        echo "lego.sh: lego run or publish failed; retrying in ${RETRY_INTERVAL}s" >&2
        sleep "$RETRY_INTERVAL"
    fi
done
