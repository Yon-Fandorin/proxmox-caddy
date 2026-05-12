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
EMPTIES=$(grep -E '^[A-Z_]+=[[:space:]]*$' .env | cut -d= -f1 | tr '\n' ' ')
if [ -n "$EMPTIES" ]; then
    cat <<EOF

  .env has empty required values:$EMPTIES
  Edit:  $INSTALL_DIR/.env
  Then:  cd $INSTALL_DIR && docker compose up -d

EOF
    exit 0
fi

# 5. Pre-create runtime dirs so they're owned by root, not by Docker on first up
mkdir -p data config

# 6. Validate + start
log "Pulling images..."
docker compose pull

log "Validating Caddyfile..."
docker compose run --rm --entrypoint caddy caddy validate \
    --config /etc/caddy/Caddyfile --adapter caddyfile

log "Starting stack..."
docker compose up -d

log "Done. Tail logs with:  docker compose logs -f caddy"
