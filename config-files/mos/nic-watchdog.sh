#!/bin/bash
# nic-watchdog.sh: detect and clear the onboard NIC's receive wedge on the MOS storage host
# (kaywoz/home0ps#310).
#
# The fault (RTL8126A on the in-tree r8169 driver, MOS kernel 6.18, linked at 5G): after loss
# bursts at a switch's 5G->2.5G step-down, the NIC silently drops received frames above roughly
# 100-500 bytes. Small pings still work; SSH, SMB, NFS and the MOS UI hang. Error counters stay 0.
# `ip link set <nic> down` + `up` clears it. This script spots that pattern and does the bounce.
#
# Detection, once per run: ping the default gateway small (56 B) and large (PROBE_SIZE, DF set).
#   both answer          healthy (remember the default route)
#   small only           WEDGED -> bounce the NIC, restore the default route, verify
#   neither              gateway/link problem, not this fault -> log only, never bounce
# Rate limit: at most MAX_PER_HOUR bounces per rolling hour; if a bounce didn't help, it waits
# COOLDOWN_MIN minutes before the next one (a bounce can't fix what isn't this fault).
#
# Cron: add the line in the MOS UI's cron jobs section. `crontab` entries are lost at reboot on MOS
# (verified 2026-11-16). Via bash, because /boot on MOS doesn't allow executing files directly:
#   * * * * *  bash /boot/config/home0ps/nic-watchdog.sh
#
#   nic-watchdog.sh            check, and bounce the NIC if wedged
#   nic-watchdog.sh --check    report only, change nothing; exit 1 if wedged or unreachable
#
# Optional settings file (host-local, not in git): /boot/config/home0ps/nic-watchdog.env
# (override with NIC_WATCHDOG_ENV=<file>). Defaults in brackets:
#   NIC_PCI=0000:01:00.0     PCI address of the NIC (its name moves between eth0/eth1 at boot)
#   PROBE_TARGET=            host to ping [the default gateway]
#   PROBE_SIZE=1000          large-probe payload in bytes; must stay below MTU-28
#   PROBES=3                 pings per probe; one reply counts as an answer
#   MAX_PER_HOUR=4           bounce budget per rolling hour
#   COOLDOWN_MIN=10          wait after a bounce that didn't help
#   LOG_FILE=/var/log/nic-watchdog.log      RAM, capped at LOG_MAX_KB [256], visible in the MOS UI
#   EVENT_FILE=/boot/config/home0ps/nic-watchdog.events   persistent, one line per bounce
#   HC_URL=                  Healthchecks ping URL (a secret: env file only, 600)
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE="${NIC_WATCHDOG_ENV:-/boot/config/home0ps/nic-watchdog.env}"
MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
NIC_PCI="${NIC_PCI:-0000:01:00.0}"; PROBE_TARGET="${PROBE_TARGET:-}"
PROBE_SIZE="${PROBE_SIZE:-1000}"; PROBES="${PROBES:-3}"
MAX_PER_HOUR="${MAX_PER_HOUR:-4}"; COOLDOWN_MIN="${COOLDOWN_MIN:-10}"
LOG_FILE="${LOG_FILE:-/var/log/nic-watchdog.log}"; LOG_MAX_KB="${LOG_MAX_KB:-256}"
EVENT_FILE="${EVENT_FILE:-/boot/config/home0ps/nic-watchdog.events}"; HC_URL="${HC_URL:-}"
STATE_DIR=/run/nic-watchdog   # RAM: route, last state, bounce times; reset at boot on purpose

log() {
  local line; line="$(date '+%F %T') nic-watchdog: $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
  command -v logger >/dev/null 2>&1 && logger -t nic-watchdog "$*" || true
  # /var/log is RAM on MOS: keep the newest half once the cap is hit
  local size; size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt $((LOG_MAX_KB * 1024)) ]; then
    tail -c $((LOG_MAX_KB * 512)) "$LOG_FILE" | sed 1d > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}
event() {   # persistent record on the boot stick, only when something happened (rare writes)
  echo "$(date '+%F %T') $*" >> "$EVENT_FILE" 2>/dev/null || true
  if [ "$(wc -l < "$EVENT_FILE" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 400 "$EVENT_FILE" > "$EVENT_FILE.tmp" && mv "$EVENT_FILE.tmp" "$EVENT_FILE"
  fi
}
hc() {   # hc ""|/fail "message"
  [ -n "$HC_URL" ] || return 0
  curl -fsS -m 10 --retry 2 --data-raw "$2" "${HC_URL%/}$1" >/dev/null 2>&1 || true
}
# log only when the state changes, so a healthy box writes nothing every minute
state_change() { local old; old=$(cat "$STATE_DIR/state" 2>/dev/null || true); echo "$1" > "$STATE_DIR/state"; [ "$old" != "$1" ]; }

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$STATE_DIR"

# one run at a time: a bounce plus verification can take longer than the cron minute.
# Nothing started here outlives the script, so the lock fd needs no closing for children.
exec 9>"$STATE_DIR/lock"
command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }

IFACE=$(ls "/sys/bus/pci/devices/$NIC_PCI/net/" 2>/dev/null | head -1 || true)
[ -n "$IFACE" ] || { state_change "no-nic" && log "no network interface at PCI $NIC_PCI (NIC_PCI wrong?)"; exit 1; }

# the default route: live if present, else the one saved on the last healthy run
ROUTE=$(ip -4 route show default | head -1 || true)
[ -n "$ROUTE" ] || ROUTE=$(cat "$STATE_DIR/route" 2>/dev/null || true)
TARGET="$PROBE_TARGET"
[ -n "$TARGET" ] || TARGET=$(awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}' <<< "$ROUTE")
[ -n "$TARGET" ] || { state_change "no-route" && log "no default route and none saved: nothing to probe"; exit 1; }

probe() { ping -n -q -c "$PROBES" -W 1 -M do -s "$1" "$TARGET" >/dev/null 2>&1; }
carrier() { [ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)" = 1 ]; }
restore_route() {   # `ip link set down` drops the default route; the address stays
  ip -4 route show default | grep . >/dev/null && return 0
  [ -n "$ROUTE" ] || return 1
  # shellcheck disable=SC2086
  ip route replace $ROUTE
}

if ! carrier; then
  state_change "no-carrier" && log "$IFACE has no carrier (cable/switch): not this fault, no action"
  [ "$MODE" = check ] && { echo "FAIL $IFACE no carrier"; exit 1; }
  exit 0
fi

SMALL=0; LARGE=0
probe 56 && SMALL=1
probe "$PROBE_SIZE" && LARGE=1

if [ "$SMALL" = 1 ] && [ "$LARGE" = 1 ]; then
  ip -4 route show default | head -1 > "$STATE_DIR/route.new" && [ -s "$STATE_DIR/route.new" ] \
    && mv "$STATE_DIR/route.new" "$STATE_DIR/route"
  state_change "ok" && log "$IFACE healthy (small and ${PROBE_SIZE} B probes answered)"
  [ "$MODE" = check ] && echo "OK   $IFACE: small and ${PROBE_SIZE} B probes to the gateway answered"
  hc "" "healthy"
  exit 0
fi

if [ "$SMALL" = 0 ]; then
  state_change "unreachable" && log "$TARGET doesn't answer small pings either: gateway/link problem, not this fault, no action"
  [ "$MODE" = check ] && { echo "FAIL $TARGET unreachable (small pings fail too)"; exit 1; }
  exit 0
fi

# small answered, large didn't: the wedge pattern. Confirm once more after a pause, so a
# moment of congestion that happened to eat the large probes doesn't cause a bounce.
sleep 5
if ! probe 56 || probe "$PROBE_SIZE"; then
  log "$IFACE: wedge pattern not confirmed on the second probe, no action"
  exit 0
fi
if [ "$MODE" = check ]; then
  echo "FAIL $IFACE wedged: small pings answered, ${PROBE_SIZE} B pings not"
  exit 1
fi

now=$(date +%s)
touch "$STATE_DIR/bounces"
awk -v t=$((now - 3600)) '$1 > t' "$STATE_DIR/bounces" > "$STATE_DIR/bounces.tmp" && mv "$STATE_DIR/bounces.tmp" "$STATE_DIR/bounces"
recent=$(( $(wc -l < "$STATE_DIR/bounces") ))
last_fail=$(cat "$STATE_DIR/last_failed" 2>/dev/null || echo 0)
if [ "$recent" -ge "$MAX_PER_HOUR" ] || [ $((now - last_fail)) -lt $((COOLDOWN_MIN * 60)) ]; then
  state_change "suppressed" && { log "$IFACE wedged, bounce suppressed (budget $recent/$MAX_PER_HOUR per hour, or cooling down after a failed bounce)"; event "suppressed $IFACE"; }
  hc /fail "wedged, bounce suppressed"
  exit 1
fi

log "$IFACE wedged (small pings answered, ${PROBE_SIZE} B not): bouncing the interface"
echo "$now" >> "$STATE_DIR/bounces"
ip link set "$IFACE" down
sleep 2
ip link set "$IFACE" up
for _ in $(seq 30); do carrier && break; sleep 1; done
sleep 3
restore_route || log "could not restore the default route"

ok=0
for _ in 1 2 3 4 5; do probe "$PROBE_SIZE" && { ok=1; break; }; sleep 3; done
if [ "$ok" = 1 ]; then
  rm -f "$STATE_DIR/last_failed"
  echo ok > "$STATE_DIR/state"
  log "$IFACE recovered after the bounce"
  event "recovered $IFACE"
  hc "" "recovered: NIC bounced"
  exit 0
fi
echo "$now" > "$STATE_DIR/last_failed"
echo failed > "$STATE_DIR/state"
log "$IFACE still not answering ${PROBE_SIZE} B pings after the bounce; next try in ${COOLDOWN_MIN} min"
event "bounce-failed $IFACE"
hc /fail "bounce did not help"
exit 1
