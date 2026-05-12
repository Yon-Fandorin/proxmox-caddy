#!/bin/sh
# First-time CrowdSec wiring: register the in-Caddy bouncer against the
# crowdsec sidecar's LAPI, drop the API key into .env, and print follow-up
# steps for Console enrollment (Community Blocklist subscription).
#
# Idempotent — safe to re-run. If .env already holds a non-empty
# CROWDSEC_BOUNCER_API_KEY it's left alone. To rotate the key, blank that
# line out and re-run.
#
# Called by install.sh once the stack is up, but can be invoked standalone:
#   sh scripts/setup-crowdsec.sh

set -eu

INSTALL_DIR="${INSTALL_DIR:-/root/proxmox-caddy}"
ENV_FILE="$INSTALL_DIR/.env"
BOUNCER_NAME="caddy-bouncer"
COMPOSE="docker compose -f $INSTALL_DIR/docker-compose.yml"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Poll LAPI until ready. Collection install runs in the entrypoint on first
# boot — pulling 4 collections over a slow link can take ~60s, occasionally
# more. 180s ceiling avoids hanging install.sh forever.
wait_for_lapi() {
    log "Waiting for crowdsec LAPI..."
    i=0
    while ! $COMPOSE exec -T crowdsec cscli lapi status >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -gt 90 ] && die "crowdsec LAPI didn't come up in 180s — check 'docker compose logs crowdsec'."
        sleep 2
    done
    log "LAPI ready."
}

[ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE — run install.sh first."

# Crowdsec must already be running — install.sh starts it before invoking us.
$COMPOSE ps --status running --quiet crowdsec | grep -q . \
    || die "crowdsec container is not running. Start it: docker compose up -d crowdsec"

wait_for_lapi

# Install LAN whitelist parser. The s02-enrich directory is populated by hub
# collections during first boot, so we drop the file in after LAPI is ready
# rather than bind-mounting over a container-managed path. cp is idempotent.
# Note: crowdsecurity/whitelists (in base collections) already whitelists
# RFC1918 — this is a belt-and-suspenders local override.
WHITELIST_SRC="$INSTALL_DIR/crowdsec/whitelists/whitelist-lan.yaml"
WHITELIST_DST="/etc/crowdsec/parsers/s02-enrich/whitelist-lan.yaml"
if [ -f "$WHITELIST_SRC" ]; then
    log "Installing LAN whitelist parser..."
    $COMPOSE exec -T crowdsec mkdir -p /etc/crowdsec/parsers/s02-enrich
    $COMPOSE cp "$WHITELIST_SRC" "crowdsec:$WHITELIST_DST"
    $COMPOSE exec -T crowdsec chmod 644 "$WHITELIST_DST" || true
    $COMPOSE restart crowdsec
    wait_for_lapi
fi

# If we already have a key in .env we're done — never overwrite silently.
CURRENT_KEY=$(grep -E '^CROWDSEC_BOUNCER_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)
if [ -n "$CURRENT_KEY" ]; then
    log "CROWDSEC_BOUNCER_API_KEY already set in .env — skipping bouncer registration."
    log "To rotate: blank the line, then re-run this script."
    exit 0
fi

# Key is empty in .env. If the bouncer already exists in LAPI we can't recover
# its key (cscli only prints it at creation), so delete + re-add.
if $COMPOSE exec -T crowdsec cscli bouncers list -o raw 2>/dev/null | grep -q "^${BOUNCER_NAME},"; then
    log "Bouncer '$BOUNCER_NAME' exists in LAPI but key missing from .env — re-registering."
    $COMPOSE exec -T crowdsec cscli bouncers delete "$BOUNCER_NAME"
fi

log "Registering bouncer '$BOUNCER_NAME'..."
KEY=$($COMPOSE exec -T crowdsec cscli bouncers add "$BOUNCER_NAME" -o raw)
[ -n "$KEY" ] || die "cscli bouncers add returned empty key."

# Write to .env. Use awk to replace the line whether it's empty or commented.
TMP="$(mktemp)"
awk -v key="$KEY" '
    /^CROWDSEC_BOUNCER_API_KEY=/ { print "CROWDSEC_BOUNCER_API_KEY=" key; found=1; next }
    { print }
    END { if (!found) print "CROWDSEC_BOUNCER_API_KEY=" key }
' "$ENV_FILE" > "$TMP"
mv "$TMP" "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "Bouncer key written to $ENV_FILE."

# If caddy is already running (standalone re-run, key rotation) recreate it
# so the new env is picked up. On first install caddy hasn't started yet —
# install.sh will start it after this script returns.
if $COMPOSE ps --status running --quiet caddy 2>/dev/null | grep -q .; then
    log "Recreating caddy with new bouncer key..."
    $COMPOSE up -d caddy
fi

cat <<EOF

Bouncer registered. To finish setup:

  1. Create a free account at https://app.crowdsec.net and copy the enroll token.
  2. Enroll this engine:
       docker compose exec crowdsec cscli console enroll <enroll-token>
  3. In the Console UI, subscribe this engine to the Community Blocklist
     (free, ~50k+ IPs aggregated from all enrolled instances).
  4. Inspect status:
       docker compose exec crowdsec cscli metrics
       docker compose exec crowdsec cscli decisions list

EOF
