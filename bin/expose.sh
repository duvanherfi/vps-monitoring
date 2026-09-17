#!/usr/bin/env bash
# Publish Grafana and Uptime Kuma through the kamal-proxy that already serves
# the apps on this host, using a Cloudflare Origin Certificate.
#
# Origin certs are only trusted by Cloudflare, so these hostnames MUST be
# proxied (orange cloud) with SSL mode "Full (strict)". That is the point:
# Cloudflare Access sits in front, and nobody reaches the login page without
# authenticating first. Let's Encrypt is not used here because ACME's HTTP-01
# challenge cannot complete through an orange-cloud record.
#
# Usage:  ./bin/expose.sh
# Expects cert.pem and key.pem in ORIGIN_DIR on the host (see README).

set -euo pipefail

GRAFANA_HOST="${GRAFANA_HOST:-metrics.TU-DOMINIO}"
KUMA_HOST="${KUMA_HOST:-status.TU-DOMINIO}"

# kamal-proxy's config volume, seen from the host and from inside the container.
ORIGIN_DIR="${ORIGIN_DIR:-/var/lib/docker/volumes/kamal-proxy-config/_data/origin}"
IN_PROXY="/home/kamal-proxy/.config/kamal-proxy/origin"
PROXY_UID=1001

for f in cert.pem key.pem; do
  if [[ ! -s "$ORIGIN_DIR/$f" ]]; then
    echo "Missing $ORIGIN_DIR/$f -- see the README section 'Exponer por dominio'." >&2
    exit 1
  fi
done

# kamal-proxy runs unprivileged; it cannot read root-owned files.
chown -R "$PROXY_UID:$PROXY_UID" "$ORIGIN_DIR"
chmod 600 "$ORIGIN_DIR/key.pem"
chmod 644 "$ORIGIN_DIR/cert.pem"

publish() {
  local name=$1 host=$2 target=$3 health=$4
  echo "--> $host -> $target"
  docker exec kamal-proxy kamal-proxy deploy "$name" \
    --target "$target" \
    --host "$host" \
    --tls \
    --tls-certificate-path "$IN_PROXY/cert.pem" \
    --tls-private-key-path "$IN_PROXY/key.pem" \
    --health-check-path "$health"
}

# Grafana answers 200 on /api/health. Uptime Kuma redirects on /, which
# kamal-proxy reads as unhealthy, so check /api/entry-page instead.
publish monitoring-grafana "$GRAFANA_HOST" grafana:3000       /api/health
publish monitoring-kuma    "$KUMA_HOST"    uptime-kuma:3001   /api/entry-page

echo
docker exec kamal-proxy kamal-proxy list
