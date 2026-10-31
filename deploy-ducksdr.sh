#!/usr/bin/env bash
#
# deploy-ducksdr.sh
#
# Permanently replace the installed OpenWebRX+ (package "openwebrx") with
# DuckSdr, built from the checkout. The existing /etc/openwebrx config and
# /var/lib/openwebrx data are preserved, so DuckSdr serves on exactly the
# same port as the instance it replaces. Nothing about the port is written.
#
# Usage:
#   bash deploy-ducksdr.sh              deploy
#   bash deploy-ducksdr.sh --rollback   restore the previously installed package
#   bash deploy-ducksdr.sh --help
#
# Environment:
#   REPO=/opt/ducksdrweb      source checkout (cloned/updated by this script)
#   KEEP_ON_FAILURE=1         do not auto-rollback if the service fails to start
#
set -euo pipefail

REPO="${REPO:-/opt/ducksdrweb}"
REPO_URL="${REPO_URL:-https://github.com/Domiko7/ducksdrweb.git}"
PKG="openwebrx"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG:-$HOME/ducksdr-deploy-${STAMP}.log}"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

trap 'printf "\nLog: %s\n" "$LOG"' EXIT
exec > >(tee -a "$LOG") 2>&1

web_port() {
python3 - <<'PY'
from configparser import ConfigParser
from pathlib import Path
c = ConfigParser()
c.read_dict({"web": {"port": "8073"}})
files = []
base = Path("/etc/openwebrx/openwebrx.conf")
if base.is_file():
    files.append(str(base))
d = Path("/etc/openwebrx/openwebrx.conf.d")
if d.is_dir():
    files += sorted(str(p) for p in d.glob("*.conf"))
c.read(files)
print(c.get("web", "port"))
PY
}

status_url() {
    local port="$1" url hostip
    hostip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    for url in "http://127.0.0.1:${port}/status" "https://127.0.0.1:${port}/status" \
               "http://localhost:${port}/status" "https://localhost:${port}/status"; do
        if curl -fsSk --max-time 2 "$url" > /tmp/ducksdr-status.json 2>/dev/null; then
            STATUS_URL="$url"
            return 0
        fi
    done
    if [ -n "$hostip" ] && curl -fsSk --max-time 2 "http://${hostip}:${port}/status" > /tmp/ducksdr-status.json 2>/dev/null; then
        STATUS_URL="http://${hostip}:${port}/status"
        return 0
    fi
    return 1
}

rollback() {
    say "Rolling back to the previously installed OpenWebRX+"
    sudo apt-mark unhold "$PKG" >/dev/null 2>&1 || true
    local deb
    deb="$(sudo ls -t /root/ducksdr-backup-*/openwebrx_*.deb 2>/dev/null | head -1 || true)"
    if [ -n "$deb" ]; then
        sudo dpkg --force-confold -i "$deb"
    else
        warn "no saved .deb found, reinstalling $PKG from the repository"
        sudo apt-get install --reinstall -y "$PKG"
    fi
    sudo systemctl restart "$PKG"
    say "Rollback finished"
}

case "${1:-}" in
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    --rollback) rollback; exit 0 ;;
esac

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it uses sudo where needed)."
for c in git curl dpkg dpkg-buildpackage sudo systemctl; do
    command -v "$c" >/dev/null || die "missing command: $c"
done

say "Preflight"
python3 -V
dpkg -s "$PKG" >/dev/null 2>&1 || die "package '$PKG' is not installed"

if [ -d "$REPO/.git" ]; then
    say "Updating $REPO"
    git -C "$REPO" pull --ff-only || die "git pull failed in $REPO; check 'git -C $REPO status' and resolve local changes"
else
    if [ -e "$REPO" ] && [ -n "$(ls -A "$REPO" 2>/dev/null)" ]; then
        die "$REPO exists but is not a git checkout; remove it or run with REPO=/some/other/path"
    fi
    say "Cloning DuckSdr into $REPO"
    sudo mkdir -p "$REPO"
    sudo chown "$(id -u):$(id -g)" "$REPO"
    git clone "$REPO_URL" "$REPO"
fi

[ -w "$REPO" ] || sudo chown -R "$(id -u):$(id -g)" "$REPO"

python3 - <<'PY'
import json
import sys
try:
    version = json.load(open("/var/lib/openwebrx/settings.json")).get("version")
except FileNotFoundError:
    version = None
print("settings.json version:", version)
if isinstance(version, int) and version > 8:
    sys.exit("ERROR: settings.json version %d is newer than this DuckSdr build supports (max 8)" % version)
PY

PORT="$(web_port)"
say "Existing web port: ${PORT} (kept unchanged)"
(cd "$REPO" && python3 -c "import owrx.version as v; print('DuckSdr source version:', v.openwebrx_version)")

say "Backing up"
BACKUP_DIR="/root/ducksdr-backup-${STAMP}"
sudo mkdir -p "$BACKUP_DIR"
sudo apt-get install --reinstall -d "$PKG" >/dev/null 2>&1 || warn "could not download the installed $PKG .deb; rollback will reinstall from the repo"
sudo cp -a /var/cache/apt/archives/openwebrx_*_all.deb "$BACKUP_DIR/" 2>/dev/null || true
sudo tar czf "$BACKUP_DIR/etc-openwebrx.tgz" -C / etc/openwebrx
sudo tar czf "$BACKUP_DIR/var-lib-openwebrx.tgz" -C /var/lib openwebrx
if status_url "$PORT"; then
    sudo cp /tmp/ducksdr-status.json "$BACKUP_DIR/status-before.json"
else
    warn "could not read the current /status endpoint (HTTPS/custom bind?); continuing"
fi
echo "$BACKUP_DIR" | sudo tee /var/lib/ducksdr-last-backup >/dev/null

say "Installing build dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq dpkg-dev fakeroot debhelper dh-python python3-all python3-setuptools

# dpkg-buildpackage writes the .deb into the parent directory, so build where
# we can actually write. /opt is often root-owned.
PARENT="$(dirname "$REPO")"
if [ -w "$PARENT" ]; then
    BUILD_DIR="$REPO"
else
    BUILD_DIR="$HOME/ducksdr-build/ducksdrweb"
    say "Cannot write to $PARENT; building in $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    tar -C "$REPO" --exclude=.git -cf - . | tar -C "$BUILD_DIR" -xf -
fi

say "Building package"
cd "$BUILD_DIR"
dpkg-buildpackage -b -us -uc
DEB="$(ls -t "$(dirname "$BUILD_DIR")"/openwebrx_*_all.deb | head -1)"
[ -n "$DEB" ] || die "build produced no .deb"

say "Installing $(basename "$DEB")"
sudo dpkg --force-confold -i "$DEB" || {
    sudo apt-get -f install -y
    sudo dpkg --force-confold -i "$DEB"
}
sudo apt-mark hold "$PKG"

say "Restarting $PKG"
sudo systemctl restart "$PKG"

OK=0
for _ in $(seq 1 30); do
    if status_url "$PORT"; then OK=1; break; fi
    sleep 1
done

if [ "$OK" -ne 1 ]; then
    printf '\nService did not answer on port %s\n' "$PORT"
    sudo journalctl -u "$PKG" -n 60 --no-pager || true
    if [ "${KEEP_ON_FAILURE:-0}" = "1" ]; then
        die "Deployment failed; leaving the new package installed (KEEP_ON_FAILURE=1)"
    fi
    rollback
    die "Deployment failed and was rolled back"
fi

PORT_AFTER="$(web_port)"
[ "$PORT_AFTER" = "$PORT" ] || die "web port changed from $PORT to $PORT_AFTER"

python3 - <<'PY'
import json
s = json.load(open("/tmp/ducksdr-status.json"))
print()
print("receiver:", s.get("receiver", {}).get("name"))
print("version :", s.get("version"))
for r in s.get("sdrs", []):
    for p in r.get("profiles", []):
        print("profile :", p.get("name"), p.get("center_freq"))
PY

say "DuckSdr is live"
echo "URL      : ${STATUS_URL%/status}"
echo "Port     : $PORT (unchanged)"
echo "Backup   : $BACKUP_DIR"
echo "Rollback : sudo bash $0 --rollback"
