#!/bin/sh
# Refresh DB-IP Lite Country mmdb for the GeoIP matcher.
#
# DB-IP publishes a new file on the 1st of each month at:
#   https://download.db-ip.com/free/dbip-country-lite-YYYY-MM.mmdb.gz
# License: CC BY 4.0 — attribution requirement applies if you re-publish
# the data, irrelevant for private origin filtering.
#
# Drops result at $INSTALL_DIR/geoip/dbip-country-lite.mmdb (a stable name —
# the docker volume mount points here, not at the dated filename) then triggers
# `caddy reload` so the matcher reopens the file.
#
# Designed for busybox sh on Alpine LXC. Idempotent on re-run.
# Cron: 0 3 1 * *  (03:00 on the 1st of each month)

set -eu

INSTALL_DIR="${INSTALL_DIR:-/root/proxmox-caddy}"
GEOIP_DIR="$INSTALL_DIR/geoip"
TARGET="$GEOIP_DIR/dbip-country-lite.mmdb"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

mkdir -p "$GEOIP_DIR"

# Compute current and previous YYYY-MM (busybox-safe — no GNU `date -d`).
y="$(date -u +%Y)"
m="$(date -u +%m)"
m_int="${m#0}"            # strip single leading zero for arithmetic
prev_m=$((m_int - 1))
prev_y="$y"
if [ "$prev_m" -eq 0 ]; then prev_m=12; prev_y=$((y - 1)); fi
CURR="$(printf '%04d-%02d' "$y" "$m_int")"
PREV="$(printf '%04d-%02d' "$prev_y" "$prev_m")"

fetch() {
    ym="$1"
    url="https://download.db-ip.com/free/dbip-country-lite-${ym}.mmdb.gz"
    log "trying $url"
    curl -fsSL --max-time 60 -o "$TMP_DIR/dbip.mmdb.gz" "$url"
}

# Current month's file may not be propagated until a few hours into the 1st;
# fall back to last month's release in that window.
if ! fetch "$CURR"; then
    log "current month not available, falling back to $PREV"
    fetch "$PREV"
fi

gunzip -f "$TMP_DIR/dbip.mmdb.gz"
mv "$TMP_DIR/dbip.mmdb" "$TARGET"
chmod 644 "$TARGET"
log "wrote $TARGET ($(wc -c < "$TARGET") bytes)"

# Reload Caddy so the GeoIP matcher reopens the new mmdb.
# `exec -T` avoids allocating a TTY (cron has none).
# `ps --quiet` returns 0 even when no container matches, so we check non-empty
# output instead of the exit code.
RUNNING="$(docker compose -f "$INSTALL_DIR/docker-compose.yml" ps --status running --quiet caddy 2>/dev/null || true)"
if [ -n "$RUNNING" ]; then
    docker compose -f "$INSTALL_DIR/docker-compose.yml" exec -T caddy \
        caddy reload --config /etc/caddy/Caddyfile
    log "caddy reloaded"
else
    log "caddy not running — skipping reload (mmdb will be picked up on next start)"
fi
