#!/usr/bin/env bash
set -euo pipefail

NEW="${NEW:-ducksdr}"
REPO="${REPO:-$(pwd)}"
WAIT="${WAIT:-90}"
PREV="${NEW}-prev"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  bash deploy-docker.sh              deploy, or update a running DuckSdr
  bash deploy-docker.sh --rollback   restore the container from before the last update
  bash deploy-docker.sh --help

Environment:
  OLD=<name>          container to replace (default: ducksdr if it exists, else openwebrx)
  NEW=ducksdr         name of the DuckSdr container
  REPO=<path>         source checkout (default: current directory)
  EXTRA_PORTS=8074:8074  extra published ports, space separated
  WAIT=90             seconds to wait for the web UI
  KEEP_ON_FAILURE=1   never roll back, keep the new container
  SKIP_CHECK=1        start the container without waiting for the web UI
EOF
}

command -v docker >/dev/null || die "docker not found"
[ -f "$REPO/owrx/version.py" ] || die "run this from the DuckSdr checkout (no owrx/version.py in $REPO)"

if [ -z "${OLD:-}" ]; then
    if docker inspect "$NEW" >/dev/null 2>&1; then
        OLD="$NEW"
    else
        OLD="openwebrx"
    fi
fi

case "${1:-}" in
    --rollback)
        if docker inspect "$PREV" >/dev/null 2>&1; then
            docker rm -f "$NEW" >/dev/null 2>&1 || true
            docker rename "$PREV" "$NEW"
            docker start "$NEW" >/dev/null
            say "Rolled back: $NEW is running the previous version"
        elif docker inspect "$OLD" >/dev/null 2>&1; then
            docker rm -f "$NEW" >/dev/null 2>&1 || true
            docker start "$OLD" >/dev/null
            say "Rolled back: $OLD is running"
        else
            die "nothing to roll back to"
        fi
        exit 0
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

docker inspect "$OLD" >/dev/null 2>&1 || die "container '$OLD' not found; check 'docker ps -a' and set OLD=<name>"

if [ -d "$REPO/.git" ]; then
    say "Updating $REPO"
    git -C "$REPO" pull --ff-only || die "git pull failed; fix the checkout in $REPO first"
fi

BASE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$OLD")"
ORIG_USER="$(docker inspect -f '{{.Config.User}}' "$OLD")"
OLD_PORTS="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$OLD")"

if [ "$OLD" = "$NEW" ]; then
    say "Update mode: replacing running container $OLD"
else
    say "Switch mode: $OLD -> $NEW"
fi
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
if [ -n "$ORIG_USER" ]; then
    printf 'USER %s\n' "$ORIG_USER" >> "$TMPD/Dockerfile"
fi

say "Building ducksdr:local (this can take a minute)"
if ! docker build -f "$TMPD/Dockerfile" --build-arg BASE_IMAGE=ducksdr-base:local -t ducksdr:local "$REPO"; then
    docker start "$OLD" >/dev/null 2>&1 || true
    die "docker build failed; $OLD restarted"
fi

cat > "$TMPD/recreate.py" <<'PY'
import json
import os
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
def publish_key(spec):
    parts = spec.split("/")[0].split(":")
    if len(parts) == 1:
        return ("", parts[0])
    return (parts[-2], parts[-1])

published = set()
for port, binds in (hc.get("PortBindings") or {}).items():
    for b in binds or []:
        host, hp = b.get("HostIp") or "", b.get("HostPort") or ""
        a += ["-p", (host + ":" if host else "") + hp + ":" + port]
        published.add((hp, port))
for extra in os.environ.get("EXTRA_PORTS", "").split():
    if publish_key(extra) in published:
        continue
    published.add(publish_key(extra))
    a += ["-p", extra]
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
printf '\nWill run:\n  %s\n\n' "$RUNC"

if [ "$OLD" = "$NEW" ]; then
    docker rm -f "$PREV" >/dev/null 2>&1 || true
    docker rename "$OLD" "$PREV"
fi
docker rm -f "$NEW" >/dev/null 2>&1 || true
if ! eval "$RUNC" >/dev/null; then
    if [ "$OLD" = "$NEW" ] && docker inspect "$PREV" >/dev/null 2>&1; then
        docker rename "$PREV" "$NEW"
        docker start "$NEW" >/dev/null 2>&1 || true
    else
        docker start "$OLD" >/dev/null 2>&1 || true
    fi
    die "docker run failed; previous container restarted"
fi

CPORT=""
PORTS="$(docker port "$NEW" 2>/dev/null || true)"
if [ -n "$PORTS" ]; then
    if printf '%s\n' "$PORTS" | grep -q '^8073/'; then
        CPORT=8073
    else
        CPORT="$(printf '%s\n' "$PORTS" | head -1 | sed 's|/.*||')"
    fi
fi
[ -n "$CPORT" ] || CPORT=8073

probe_inside() {
    docker exec -i "$NEW" python3 - "$CPORT" <<'PY' 2>/dev/null
import ssl, sys, urllib.request
port = sys.argv[1]
ctx = ssl._create_unverified_context()
for scheme in ("http", "https"):
    try:
        with urllib.request.urlopen("%s://127.0.0.1:%s/status" % (scheme, port), timeout=3, context=ctx) as r:
            sys.stdout.write(r.read().decode())
        break
    except Exception:
        continue
PY
}

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSk --max-time 3 "$1"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$1" <<'PY'
import ssl, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=3, context=ssl._create_unverified_context()) as r:
    sys.stdout.write(r.read().decode())
PY
    else
        return 1
    fi
}

host_urls() {
    local hp ip p
    if [ -n "$PORTS" ]; then
        printf '%s\n' "$PORTS" | sed 's|.*->||' | while read -r hp; do
            printf 'http://%s/status\n' "$hp"
            printf 'https://%s/status\n' "$hp"
        done
    fi
    for p in "$CPORT" 8073; do
        printf 'http://127.0.0.1:%s/status\n' "$p"
        printf 'http://localhost:%s/status\n' "$p"
    done
    for ip in $(hostname -I 2>/dev/null || true); do
        printf 'http://%s:%s/status\n' "$ip" "$CPORT"
    done
    true
}

host_probe() {
    local url body
    for url in $(host_urls); do
        if body="$(http_get "$url" 2>/dev/null)" && [ -n "$body" ]; then
            HOST_URL="$url"
            printf '%s' "$body" > /tmp/duck-docker-status.json
            return 0
        fi
    done
    return 1
}

app_ready_in_logs() {
    docker logs --tail 80 "$NEW" 2>&1 | grep -q "Ready to serve requests"
}

INSIDE=0
if docker exec "$NEW" python3 -c 'pass' >/dev/null 2>&1; then
    INSIDE=1
fi

say "Waiting for the web UI (up to ${WAIT}s)"
STATUS_JSON=""
HOST_URL=""
OK=0
[ "${SKIP_CHECK:-0}" = "1" ] && OK=1
if [ "$OK" -ne 1 ]; then
    for _ in $(seq 1 "$WAIT"); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$NEW" 2>/dev/null)" != "true" ]; then
            break
        fi
        if [ "$INSIDE" = 1 ] && STATUS_JSON="$(probe_inside)" && [ -n "$STATUS_JSON" ]; then
            OK=1
            break
        fi
        if host_probe; then
            OK=1
            break
        fi
        if app_ready_in_logs; then
            OK=1
            break
        fi
        sleep 1
    done
fi

if [ "$OK" -eq 1 ]; then
    sleep 2
    if [ "$(docker inspect -f '{{.State.Running}}' "$NEW" 2>/dev/null)" != "true" ]; then
        OK=0
    fi
fi

if [ "$OK" -ne 1 ]; then
    printf '\nContainer state:\n'
    docker ps -a --filter "name=^${NEW}$" --format '  {{.Status}}' || true
    printf '\nPort mappings:\n'
    docker port "$NEW" 2>/dev/null | sed 's/^/  /' || true
    printf '\nLast log lines:\n'
    docker logs --tail 60 "$NEW" 2>&1 || true
    if [ "$(docker inspect -f '{{.State.Running}}' "$NEW" 2>/dev/null)" = "true" ] || [ "${KEEP_ON_FAILURE:-0}" = "1" ]; then
        die "container $NEW is running but did not answer the probe; left in place (rollback: bash $0 --rollback)"
    fi
    docker rm -f "$NEW" >/dev/null 2>&1 || true
    if [ "$OLD" = "$NEW" ] && docker inspect "$PREV" >/dev/null 2>&1; then
        docker rename "$PREV" "$NEW"
        docker start "$NEW" >/dev/null 2>&1 || true
        die "DuckSdr did not answer; restored the previous $NEW"
    fi
    docker start "$OLD" >/dev/null 2>&1 || true
    die "DuckSdr did not answer; rolled back to $OLD"
fi

NEW_PORTS="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$NEW")"
if [ "$OLD_PORTS" != "$NEW_PORTS" ]; then
    warn "port bindings differ: was $OLD_PORTS, now $NEW_PORTS"
fi

[ -n "$STATUS_JSON" ] || STATUS_JSON="$(cat /tmp/duck-docker-status.json 2>/dev/null || true)"
python3 - "$STATUS_JSON" <<'PY'
import json
import sys
try:
    s = json.loads(sys.argv[1])
except Exception:
    print()
    sys.exit(0)
print()
print("receiver:", (s.get("receiver") or {}).get("name"))
print("version :", s.get("version"))
PY

say "DuckSdr is live"
if [ -n "$HOST_URL" ]; then
    echo "  URL       : ${HOST_URL%/status}"
else
    warn "the app answers inside the container but nothing responded from WSL; check the published port"
    echo "  Port      : $CPORT in container"
fi
echo "  Container : $NEW"
echo "  Logs      : docker logs -f $NEW"
echo "  Rollback  : bash $0 --rollback"
if [ "$OLD" = "$NEW" ]; then
    echo "  Previous  : $PREV (stopped; replaced on the next update)"
    echo "  Cleanup   : docker rm $PREV"
elif docker inspect "$OLD" >/dev/null 2>&1; then
    echo "  Previous  : $OLD (stopped)"
    echo "  Cleanup   : docker rm $OLD"
fi
