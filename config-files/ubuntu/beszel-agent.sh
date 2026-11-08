#!/bin/bash
# beszel-agent.sh — harden a NATIVE Beszel agent (systemd service from Beszel's install script)
# on Ubuntu/Debian hosts in home0ps (kaywoz/home0ps#138). Run after the host's read-only
# docker-socket-proxy is up on 127.0.0.1:2375 (docker-compose/<host>/compose.yaml).
#
#   sudo ./beszel-agent.sh              # apply, then verify
#   sudo ./beszel-agent.sh --dry-run    # show what would change
#   sudo ./beszel-agent.sh --verify     # only run the checks
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/<commit>/config-files/ubuntu/beszel-agent.sh | sudo bash -s -- --dry-run
#
# What it does:
#   * drop-in /etc/systemd/system/beszel-agent.service.d/home0ps.conf (survives agent updates and
#     re-runs of the install script, which only edit the main unit):
#       LISTEN=<tailnet-ip>:45876          only the tailnet address; LISTEN wins over the unit's PORT
#                                          (beszel agent/server.go, GetAddress)
#       DOCKER_HOST=tcp://127.0.0.1:2375   Docker only through the read-only proxy (POST=0)
#       After/Wants=tailscaled.service     the tailnet address exists before the agent binds it
#   * removes user beszel from the `docker` group (full socket = root) and, on VMs/containers,
#     from `disk` (raw block devices; only useful for S.M.A.R.T. on bare metal)
#   * restarts the agent
# The hub key and token stay in the main unit; this script never reads or prints them.
set -euo pipefail
export LC_ALL=C LANG=C

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --verify) MODE=verify ;;
  -h|--help) sed -n '2,24p' "$0" 2>/dev/null || true; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" = 0 ] || { echo "This script must be run as root" >&2; exit 1; }

UNIT=beszel-agent
DROPIN_DIR=/etc/systemd/system/${UNIT}.service.d
DROPIN=$DROPIN_DIR/home0ps.conf
PROXY=tcp://127.0.0.1:2375
FAILS=0
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32mOK\e[0m   %s\n' "$*"; }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }

systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "no $UNIT service here (native agent not installed)" >&2; exit 1; }
id beszel >/dev/null 2>&1 || { echo "no user beszel" >&2; exit 1; }
TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TS_IP" ] || { echo "no tailnet IPv4 (tailscale up?)" >&2; exit 1; }
VIRT=$(systemd-detect-virt 2>/dev/null || true)   # "none" on bare metal
in_group() { id -nG beszel | tr ' ' '\n' | grep -qx "$1"; }

if [ "$MODE" != verify ]; then
  step "drop-in $DROPIN"
  WANT="[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Environment=\"LISTEN=${TS_IP}:45876\"
Environment=\"DOCKER_HOST=${PROXY}\""
  if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$WANT" ]; then
    echo "  unchanged"
  else
    run mkdir -p "$DROPIN_DIR"
    if [ "$MODE" = dry ]; then printf '  + write:\n%s\n' "$WANT"; else printf '%s\n' "$WANT" > "$DROPIN"; chmod 644 "$DROPIN"; fi
  fi

  step "groups"
  if in_group docker; then run gpasswd -d beszel docker; else echo "  not in docker"; fi
  if in_group disk; then
    if [ "$VIRT" != none ]; then run gpasswd -d beszel disk
    else echo "  bare metal: keeping disk (S.M.A.R.T.) — accepted risk, raw disk access"; fi
  else echo "  not in disk"; fi

  step "restart"
  run systemctl daemon-reload
  run systemctl restart "$UNIT"
  [ "$MODE" = dry ] && exit 0
  sleep 3
fi

step "verify"
systemctl is-active --quiet "$UNIT" && ok "$UNIT running" || bad "$UNIT not running (journalctl -u $UNIT)"
grep -qx "Environment=\"LISTEN=${TS_IP}:45876\"" "$DROPIN" 2>/dev/null && ok "LISTEN=${TS_IP}:45876 in drop-in" || bad "drop-in missing or LISTEN not ${TS_IP}:45876"
L=$(ss -Hltnp 2>/dev/null | awk '/beszel-agent/ {print $4}' | sort -u | tr '\n' ' ')
[ "$L" = "${TS_IP}:45876 " ] && ok "listens only on ${TS_IP}:45876" || bad "listens on: ${L:-nothing}"
in_group docker && bad "beszel in docker group (full socket)" || ok "beszel not in docker group"
if in_group disk; then [ "$VIRT" = none ] && ok "beszel in disk (bare metal, S.M.A.R.T.)" || bad "beszel in disk on a $VIRT guest"
else ok "beszel not in disk"; fi
curl -s --max-time 5 http://127.0.0.1:2375/_ping | grep -qx OK && ok "read-only proxy answers on 127.0.0.1:2375" || bad "no proxy on 127.0.0.1:2375 (Docker stats will be missing)"
if journalctl -u "$UNIT" --since "-2min" --no-pager 2>/dev/null | grep -qi 'connection failed'; then
  bad "WebSocket to the hub failed in the last 2 minutes (journalctl -u $UNIT)"
else
  echo "  no hub connection errors in the last 2 minutes — confirm the host is green in Beszel"
fi

echo; [ "$FAILS" = 0 ] && echo "all checks passed" || { echo "$FAILS check(s) failed"; exit 1; }
