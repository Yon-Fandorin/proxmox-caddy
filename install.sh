#!/bin/sh
# Proxmox-Caddy bootstrap installer for Alpine LXC.
#
# Usage (public repo):
#   curl -fsSL https://raw.githubusercontent.com/Yon-Fandorin/proxmox-caddy/main/install.sh | sh
#
# Usage (private repo with PAT):
#   curl -fsSL -H "Authorization: token $GH_PAT" \
#     https://raw.githubusercontent.com/Yon-Fandorin/proxmox-caddy/main/install.sh \
#     | GH_PAT=$GH_PAT sh
#
# Override defaults via env:
#   REPO=Yon-Fandorin/proxmox-caddy  BRANCH=main  INSTALL_DIR=/root/proxmox-caddy

set -eu

REPO="${REPO:-Yon-Fandorin/proxmox-caddy}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/root/proxmox-caddy}"
GH_PAT="${GH_PAT:-}"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Sanity
[ "$(id -u)" = "0" ] || die "Run as root."
grep -qi alpine /etc/os-release 2>/dev/null || log "Warning: not Alpine. Proceeding."

# 2. Docker
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker + compose plugin..."
    apk update >/dev/null
    apk add --no-cache docker docker-cli-compose curl tar
    rc-update add docker boot >/dev/null
    service docker start
    # Wait for daemon
    for _ in 1 2 3 4 5; do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
fi
docker info >/dev/null 2>&1 || die "Docker daemon not running."

# 3. Fetch project
log "Downloading $REPO@$BRANCH -> $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
if [ -n "$GH_PAT" ]; then
    AUTH_HEADER="Authorization: token $GH_PAT"
    TARBALL_URL="https://api.github.com/repos/${REPO}/tarball/${BRANCH}"
    curl -fsSL -H "$AUTH_HEADER" -H "Accept: application/vnd.github.v3.raw" \
        "$TARBALL_URL" | tar xz -C "$INSTALL_DIR" --strip-components=1
else
    curl -fsSL "$TARBALL_URL" | tar xz -C "$INSTALL_DIR" --strip-components=1
fi

cd "$INSTALL_DIR"

# 4. .env
if [ ! -f .env ]; then
    cp .env.example .env
    log ".env created from template."
fi

# Catch any KEY= line with empty value — these silently produce broken URLs at
# runtime (e.g. https://:8006). Bare-defaults like PVE_PORT=8006 are skipped.
# CROWDSEC_BOUNCER_API_KEY is intentionally blank on first run — setup-crowdsec.sh
# fills it in below. Excluded from the empty-check.
EMPTIES=$(grep -E '^[A-Z_]+=[[:space:]]*$' .env \
    | grep -vE '^(CROWDSEC_BOUNCER_API_KEY)=' \
    | cut -d= -f1 | tr '\n' ' ')
if [ -n "$EMPTIES" ]; then
    cat <<EOF

  .env has empty required values:$EMPTIES
  Edit:  $INSTALL_DIR/.env
  Then:  cd $INSTALL_DIR && sh install.sh

EOF
    exit 0
fi

# 5. Pre-create runtime dirs so they're owned by root, not by Docker on first up.
#    crowdsec/{config,data} hold persistent state (collection installs, decision
#    DB); acquis.d ships in the repo (read-only mount).
mkdir -p data config geoip crowdsec/config crowdsec/data

# 6. Threat data — DB-IP Lite mmdb must exist before Caddy starts (KR_ONLY
#    matcher opens it at config-load time). On fresh install Caddy isn't
#    running yet so the script's reload step is a graceful no-op.
log "Seeding GeoIP database (DB-IP Lite)..."
INSTALL_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/scripts/update-dbip.sh" \
    || die "DB-IP Lite download failed — fix network and re-run."

# 7. Pull images.
log "Pulling images..."
docker compose pull

# 8. Bootstrap order matters: Caddy's global `crowdsec` block needs a non-empty
#    api_key at startup. We start crowdsec first, register the bouncer (which
#    writes the key into .env), THEN validate + start caddy with the key in place.
log "Starting crowdsec sidecar..."
docker compose up -d crowdsec

log "Wiring CrowdSec bouncer into Caddy..."
INSTALL_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/scripts/setup-crowdsec.sh" \
    || die "CrowdSec bouncer setup failed — see 'docker compose logs crowdsec'."

log "Validating Caddyfile..."
docker compose run --rm --entrypoint caddy caddy validate \
    --config /etc/caddy/Caddyfile --adapter caddyfile

log "Starting caddy..."
docker compose up -d caddy

# 9. Cron — schedule monthly mmdb refresh. CrowdSec self-updates its decision
#    DB on its own cadence via LAPI, so no cron entry needed for it.
log "Installing cron jobs..."
CRON_FILE="/etc/crontabs/root"
mkdir -p /etc/crontabs
# Strip any previous block we wrote (between BEGIN/END markers).
if [ -f "$CRON_FILE" ]; then
    sed -i '/# >>> proxmox-caddy >>>/,/# <<< proxmox-caddy <<</d' "$CRON_FILE"
fi
cat >> "$CRON_FILE" <<EOF
# >>> proxmox-caddy >>>
# DB-IP Lite Country mmdb — monthly (DB-IP releases on the 1st)
0 3 1 * * INSTALL_DIR=$INSTALL_DIR $INSTALL_DIR/scripts/update-dbip.sh >> $INSTALL_DIR/data/cron.log 2>&1
# <<< proxmox-caddy <<<
EOF
# crond picks up changes automatically via inotify on Alpine; restart anyway
# to be sure (no-op if already running).
rc-update add crond default >/dev/null 2>&1 || true
service crond restart >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true

log "Done."
log "Logs:           docker compose logs -f caddy crowdsec"
log "Decisions:      docker compose exec crowdsec cscli decisions list"
log "Cron output:    tail -f $INSTALL_DIR/data/cron.log"
log ""
log "Final step (optional, recommended): enroll in CrowdSec Console for"
log "Community Blocklist — see 'sh scripts/setup-crowdsec.sh' output above."
