#!/bin/bash
# docker-userns.sh: keep MOS's Docker on userns-remap, and alert when it isn't (kaywoz/home0ps#310 §7c).
#
# Why: MOS 0.6.2 has no usable setting for Docker daemon options (`docker_options` in
# /boot/config/docker.json is passed at boot, but the UI resets it and has no field), and /etc,
# where dockerd reads daemon.json and the subuid ranges, is RAM and rebuilt at every boot.
#
# Runs twice:
#   * at boot, from /boot/optional/scripts/pre-start.sh (see pre-start.sh here), which mos-start
#     runs BEFORE Docker, LXC and cron: writes the config, Docker isn't running yet, exits. Docker's
#     first start is then remapped, and MOS's container autostart starts the stacks in that root.
#   * every minute from MOS UI cron, as a guard: re-applies the config (in case Docker is started
#     outside boot) and checks Docker's state.
#
# Every run:
#   1. writes the remap config if missing: pinned range in /etc/subuid + /etc/subgid, the user,
#      /etc/docker/daemon.json. Never starts Docker.
#   2. Docker running remapped              -> quiet (Healthchecks ping)
#      Docker running WITHOUT remap         -> fallback (pre-start didn't run): restart Docker once
#                                              per boot, verify, else alert. The init script's stop
#                                              `docker stop`s compose containers, so stacks that
#                                              MOS's autostart already started stay down: alert.
#      Docker not running                   -> nothing (disabled, or MOS hasn't started it yet)
#
# Defensive, because a MOS update can change what this relies on:
#   * the uid range is pinned (never Docker's "default": LXC's root:100000 range may come up after
#     Docker, so an automatic pick at boot could land on 100000; a moved range breaks the ownership
#     of all appdata); another range overlapping it -> abort + alert
#   * a daemon.json it didn't write -> abort + alert (MOS may have started managing it)
#   * /etc/init.d/docker no longer matching the recorded checksum -> alert (still acts)
#
# Install (host): /boot is noexec, hence bash.
#   /boot/config/home0ps/docker-userns.sh       this file, 600
#   /boot/config/home0ps/docker-userns.env      settings, 600 (docker-userns.env.example)
#   /boot/optional/scripts/pre-start.sh         pre-start.sh here, 600
#   MOS UI cron:  * * * * *  bash /boot/config/home0ps/docker-userns.sh
#   docker-userns.sh --check   report only, change nothing; exit 1 unless Docker runs remapped
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE="${DOCKER_USERNS_ENV:-/boot/config/home0ps/docker-userns.env}"
MODE=apply
case "${1:-}" in --check) MODE=check ;; "") ;; *) echo "unknown option: $1" >&2; exit 1 ;; esac
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
REMAP_USER="${REMAP_USER:-dockremap}"; BASE="${REMAP_BASE:-165536}"; RANGE="${REMAP_RANGE:-65536}"
INIT_SHA="${INIT_SHA:-}"; HC_URL="${HC_URL:-}"
INIT=/etc/init.d/docker; CONF=/etc/docker/daemon.json
LOG=/var/log/docker-userns.log; EVENTS=/boot/config/home0ps/docker-userns.events
STATE=/run/docker-userns   # RAM: reset at boot on purpose

log()   { local l; l="$(date '+%F %T') docker-userns: $*"; echo "$l"; echo "$l" >> "$LOG" 2>/dev/null || true; }
event() { echo "$(date '+%F %T') $*" >> "$EVENTS" 2>/dev/null || true; }
hc()    { [ -n "$HC_URL" ] || return 0; curl -fsS -m 10 --retry 2 --data-raw "$2" "${HC_URL%/}$1" >/dev/null 2>&1 || true; }
state_change() { local o; o=$(cat "$STATE/state" 2>/dev/null || true); echo "$1" > "$STATE/state"; [ "$o" != "$1" ]; }
alert() { state_change "alert:$2" && { log "$1"; event "$2"; }; hc /fail "$1"; }

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

running()  { docker info >/dev/null 2>&1; }
remapped() { docker info --format '{{.DockerRootDir}} {{.SecurityOptions}}' 2>/dev/null \
               | grep -q "/${BASE}\.${BASE} .*name=userns"; }
init_ok()  { [ -z "$INIT_SHA" ] || [ "$(sha256sum "$INIT" | cut -d' ' -f1)" = "$INIT_SHA" ]; }
ours()     { grep -q "\"userns-remap\": \"$REMAP_USER\"" "$CONF" 2>/dev/null; }

if [ "$MODE" = check ]; then   # read-only: no lock needed
  init_ok && echo "init script: as reviewed${INIT_SHA:+ (checksum matches)}" || echo "WARN init script changed since review"
  ours && echo "config: $CONF in place" || echo "WARN $CONF missing or not ours"
  if running && remapped; then echo "OK   Docker runs remapped ($(docker info --format '{{.DockerRootDir}}'))"; exit 0; fi
  running && echo "FAIL Docker runs WITHOUT userns-remap" || echo "FAIL Docker not running"
  exit 1
fi

mkdir -p "$STATE"
# one run at a time. Docker restarted below must NOT inherit fd 9 (closed for the init script),
# or dockerd holds the lock for its lifetime and every later run exits silently.
exec 9>"$STATE/lock"; command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }

if ! init_ok; then   # once per boot, own flag: it mustn't flip the main state every minute
  [ -e "$STATE/init-warned" ] || { touch "$STATE/init-warned"; log "$INIT changed since review (MOS update?): review it"; event "init-changed"; }
  hc /fail "$INIT changed since review"
fi

# --- 1. config in place (never starts Docker) ---
if [ -s "$CONF" ] && ! ours; then
  alert "$CONF exists and isn't ours (MOS update?): not touching Docker" "foreign-daemon-json"; exit 1
fi
for f in /etc/subuid /etc/subgid; do
  touch "$f"
  grep -qx "${REMAP_USER}:${BASE}:${RANGE}" "$f" && continue
  if awk -F: -v u="$REMAP_USER" -v b="$BASE" -v r="$RANGE" \
       '$1 != u && NF == 3 && $2 < b + r && $2 + $3 > b {bad=1} END {exit !bad}' "$f"; then
    alert "$f has another range overlapping $BASE:$RANGE: not touching Docker" "range-overlap"; exit 1
  fi
  sed -i "/^${REMAP_USER}:/d" "$f"; echo "${REMAP_USER}:${BASE}:${RANGE}" >> "$f"
done
getent passwd "$REMAP_USER" >/dev/null || useradd --system --no-create-home --shell /bin/false "$REMAP_USER"
if ! ours; then
  mkdir -p /etc/docker
  printf '{\n  "userns-remap": "%s"\n}\n' "$REMAP_USER" > "$CONF"
  log "remap config written ($REMAP_USER $BASE:$RANGE); applies to the next Docker start"
fi

# --- 2. Docker's state ---
running || exit 0
if remapped; then state_change ok && log "Docker runs remapped"; hc "" "remapped"; exit 0; fi

if [ -e "$STATE/restarted" ]; then
  alert "Docker runs WITHOUT userns-remap after this boot's restart: check $CONF and the init script" "unremapped"
  exit 1
fi
touch "$STATE/restarted"
log "Docker runs without remap (started before the config existed): restarting it once"
"$INIT" restart >/dev/null 2>&1 9>&- || true
for _ in $(seq 60); do running && break; sleep 1; done
if running && remapped; then
  state_change ok; log "Docker restarted, remapped ($(docker info --format '{{.DockerRootDir}}'))"
  event "restarted-remapped"; hc "" "restarted remapped"; exit 0
fi
alert "Docker didn't come back remapped after the restart (running: $(running && echo yes || echo no))" "restart-failed"
exit 1
