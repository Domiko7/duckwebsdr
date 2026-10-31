#!/usr/bin/env bash
#
# deploy-docker.sh
#
# Replace a Docker-based OpenWebRX+ container with DuckSdr, keeping the same
# port, the same devices, the same volumes and the same in-container config.
#
# Run it from the DuckSdr source checkout:
#   bash deploy-docker.sh
#   bash deploy-docker.sh --rollback
#
# Environment:
#   OLD=openwebrx      existing container name
#   NEW=ducksdr        new container name
#   KEEP_ON_FAILURE=1  leave the failed container in place instead of rolling back
#
set -euo pipefail

OLD="${OLD:-openwebrx}"
NEW="${NEW:-ducksdr}"
REPO="${REPO:-$(pwd)}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
[ -f "$REPO/owrx/version.py" ] || die "run this from the DuckSdr checkout (no owrx/version.py in $REPO)"

case "${1:-}" in
    --rollback)
        docker rm -f "$NEW" >/dev/null 2>&1 || true
        docker start "$OLD"
        say "Rolled back: $OLD is running, $NEW removed"
        exit 0
        ;;
    --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
esac

docker inspect "$OLD" >/dev/null 2>&1 || die "container '$OLD' not found; check 'docker ps -a' and set OLD=<name>"

if [ -d "$REPO/.git" ]; then
    say "Updating $REPO"
    git -C "$REPO" pull --ff-only || die "git pull failed; resolve local changes in $REPO first"
fi

BASE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$OLD")"
ORIG_USER="$(docker inspect -f '{{.Config.User}}' "$OLD")"
say "Existing container : $OLD (image $BASE_IMAGE)"
say "Source checkout    : $REPO"

if [ "$(docker inspect -f '{{.State.Running}}' "$OLD")" = "true" ]; then
    say "Stopping $OLD"
    docker stop "$OLD" >/dev/null
fi

say "Snapshotting $OLD so its in-container config/data is kept"
docker commit "$OLD" ducksdr-base:local >/dev/null

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

cat > "$TMPD/Dockerfile" <<EOF
ARG BASE_IMAGE
FROM \${BASE_IMAGE}
USER root
COPY owrx /tmp/__duck/owrx
COPY csdr /tmp/__duck/csdr
COPY htdocs /tmp/__duck/htdocs
RUN set -eux; \\
    SITE="\$(python3 -c 'import importlib.util, os; s = importlib.util.find_spec("owrx.version"); assert s and s.origin, "owrx not found"; print(os.path.dirname(os.path.dirname(s.origin)))')"; \\
    echo "Replacing OpenWebRX in \$SITE with DuckSdr"; \\
    rm -rf "\$SITE/owrx" "\$SITE/csdr" "\$SITE/htdocs"; \\
    cp -a /tmp/__duck/owrx "\$SITE/owrx"; \\
    cp -a /tmp/__duck/csdr "\$SITE/csdr"; \\
    cp -a /tmp/__duck/htdocs "\$SITE/htdocs"; \\
    find "\$SITE/owrx" "\$SITE/csdr" "\$SITE/htdocs" -name __pycache__ -type d -exec rm -rf {} +; \\
    rm -rf /tmp/__duck
EOF
[ -n "$ORIG_USER" ] && printf 'USER %s\n' "$ORIG_USER" >> "$TMPD/Dockerfile"

say "Building ducksdr:local (this can take a minute)"
docker build -f "$TMPD/Dockerfile" --build-arg BASE_IMAGE=ducksdr-base:local -t ducksdr:local "$REPO"

cat > "$TMPD/recreate.py" <<'PY'
import json
import shlex
import sys

new_name, image = sys.argv[1], sys.argv[2]
c = json.load(sys.stdin)[0]
hc, cc = c.get("HostConfig") or {}, c.get("Config") or {}
a = ["docker", "run", "-d", "--name", new_name]

for b in hc.get("Binds") or []:
    a += ["-v", b]
for m in hc.get("Mounts") or []:
    if m.get("Type") == "volume":
        src = m.get("Name") or m.get("Source")
        if src:
            a += ["-v", src + ":" + m["Destination"] + ("" if m.get("RW", True) else ":ro")]
    elif m.get("Type") == "tmpfs":
        a += ["--tmpfs", m["Destination"]]
for port, binds in (hc.get("PortBindings") or {}).items():
    for b in binds or []:
        host, hp = b.get("HostIp") or "", b.get("HostPort") or ""
        a += ["-p", (host + ":" if host else "") + hp + ":" + port]
for d in hc.get("Devices") or []:
    a += ["--device", d["PathOnHost"] + ":" + d["PathInContainer"] + ":" + d.get("CgroupPermissions", "rwm")]
for e in cc.get("Env") or []:
    if e.split("=", 1)[0] not in {"PATH", "HOSTNAME", "HOME", "TERM"}:
        a += ["-e", e]
if hc.get("NetworkMode") and hc["NetworkMode"] != "default":
    a += ["--network", hc["NetworkMode"]]
rp = (hc.get("RestartPolicy") or {}).get("Name")
if rp and rp != "no":
    a += ["--restart", rp]
if hc.get("Privileged"):
    a += ["--privileged"]
for g in hc.get("GroupAdd") or []:
    a += ["--group-add", g]
for cap in hc.get("CapAdd") or []:
    a += ["--cap-add", cap]
if hc.get("PidMode"):
    a += ["--pid", hc["PidMode"]]
if hc.get("IpcMode"):
    a += ["--ipc", hc["IpcMode"]]
if cc.get("User"):
    a += ["--user", cc["User"]]
if cc.get("WorkingDir"):
    a += ["-w", cc["WorkingDir"]]
if cc.get("Hostname"):
    a += ["--hostname", cc["Hostname"]]
for s in hc.get("SecurityOpt") or []:
    a += ["--security-opt", s]
for u in hc.get("Ulimits") or []:
    a += ["--ulimit", u["Name"] + "=" + str(u["Soft"]) + ":" + str(u["Hard"])]
ep = cc.get("Entrypoint")
if ep:
    a += ["--entrypoint", ep[0]]
a.append(image)
a += cc.get("Cmd") or []
print(shlex.join(a))
PY

say "Reconstructing the run configuration of $OLD"
RUNC="$(docker inspect "$OLD" | python3 "$TMPD/recreate.py" "$NEW" "ducksdr:local")"
echo
echo "Will run:"
echo "  $RUNC"
echo

docker rm -f "$NEW" >/dev/null 2>&1 || true
eval "$RUNC"

say "Waiting for the web UI"
PORT="$(docker port "$NEW" 8073/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
[ -n "$PORT" ] || PORT=8073

OK=0
for _ in $(seq 1 40); do
    if curl -fsSk --max-time 2 "http://127.0.0.1:${PORT}/status" > /tmp/duck-docker-status.json 2>/dev/null \
       || curl -fsSk --max-time 2 "https://127.0.0.1:${PORT}/status" > /tmp/duck-docker-status.json 2>/dev/null; then
        OK=1
        break
    fi
    sleep 1
done

if [ "$OK" -ne 1 ]; then
    echo
    docker logs --tail 60 "$NEW" || true
    if [ "${KEEP_ON_FAILURE:-0}" = "1" ]; then
        die "DuckSdr did not answer on port $PORT (KEEP_ON_FAILURE=1, container $NEW left in place)"
    fi
    docker rm -f "$NEW" >/dev/null 2>&1 || true
    docker start "$OLD" >/dev/null 2>&1 || true
    die "DuckSdr did not answer on port $PORT; rolled back to $OLD"
fi

python3 - <<'PY'
import json
s = json.load(open("/tmp/duck-docker-status.json"))
print()
print("receiver:", s.get("receiver", {}).get("name"))
print("version :", s.get("version"))
PY

say "DuckSdr is live on port $PORT"
echo "  Container : $NEW"
echo "  Logs      : docker logs -f $NEW"
echo "  Rollback  : docker rm -f $NEW && docker start $OLD   (or: bash $0 --rollback)"
echo "  Cleanup   : docker rm $OLD    (only once you are happy)"
