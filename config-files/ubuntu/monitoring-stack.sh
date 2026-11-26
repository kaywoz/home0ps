#!/bin/bash
# monitoring-stack.sh: lay out, start, serve and verify the monitoring stack (docker-compose/monitoring/)
# on the monitoring host. Run baseline.sh and docker-host.sh first.
#
# Run from a home0ps checkout on the host (the stack files are taken from it):
#   sudo ./config-files/ubuntu/monitoring-stack.sh --dry-run   show what would change
#   sudo ./config-files/ubuntu/monitoring-stack.sh             files, permissions, .env values, start
#   sudo ./config-files/ubuntu/monitoring-stack.sh --serve     publish the four UIs as Tailscale Services
#   sudo ./config-files/ubuntu/monitoring-stack.sh --verify    check everything, change nothing; exit 1 on a failure
#
# Re-runnable: files are replaced only when they differ from the checkout; .env values that are set are
# kept; nothing prints a secret. Steps that stay manual (interactive, once):
#   ./gatus-set-password.sh, ./dozzle-setup.sh (both from /srv/docker), the Healthchecks admin
#   (docker compose exec healthchecks /opt/healthchecks/manage.py createsuperuser), Beszel's first login and
#   "Add system" with host 172.31.250.1 port 45876, gatus/config/heartbeat.yaml and alerting.yaml.
# Settings (environment, optional):
#   STACK_DIR=/srv/docker     where the stack lives (CLAUDE.md §8 host layout)
set -Eeuo pipefail
trap 'echo "monitoring-stack.sh: failed on line $LINENO" >&2' ERR
export LC_ALL=C

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --serve) MODE=serve ;;
  --verify) MODE=verify ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../docker-compose/monitoring" && pwd)"
[ -f "$SRC/compose.yaml" ] || { echo "No stack files at $SRC: run from a home0ps checkout." >&2; exit 1; }
D="${STACK_DIR:-/srv/docker}"
ADMIN="${SUDO_USER:-}"; [ "$ADMIN" = root ] && ADMIN=""
REMAP=165534     # container uid 65534 under userns-remap (base 100000)
NOBODY=65534     # Beszel agent: host user namespace, real nobody
# Service -> local port, as published in compose.yaml
SERVICES="gatus:8081 beszel:8090 dozzle:8082 healthchecks:8085"

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }
envval() { sed -n "s/^$1=//p" "$D/.env" 2>/dev/null | head -1 | tr -d '"'; }   # value only, never printed
setenv() {   # setenv KEY VALUE: replace the KEY= line (value not echoed)
  if [ "$MODE" = dry ]; then echo "  + set $1 in .env"; return; fi
  local t; t=$(mktemp)
  awk -v k="$1" -v v="$2" 'BEGIN{done=0} $0 ~ "^"k"=" {print k"=\""v"\""; done=1; next} {print} END{if(!done) print k"=\""v"\""}' "$D/.env" > "$t"
  [ -s "$t" ] && install -m 600 -o "${ADMIN:-root}" "$t" "$D/.env"; rm -f "$t"
}
dc() { (cd "$D" && docker compose "$@"); }
ts_json() { tailscale status --json 2>/dev/null || true; }

# ---- files: the stack from the checkout -------------------------------------------------------------
files() {
  step "files: $SRC -> $D"
  [ -d "$D" ] || { bad "$D missing (run docker-host.sh first)"; return; }
  local f mode
  for f in compose.yaml .gitignore gatus-set-password.sh dozzle-setup.sh hc-setup.sh gatus/config/config.yaml; do
    case "$f" in *.sh) mode=755 ;; *) mode=644 ;; esac
    if cmp -s "$SRC/$f" "$D/$f"; then ok "$f up to date"
    else note "$f differs: installing"; run install -D -m "$mode" -o "${ADMIN:-root}" "$SRC/$f" "$D/$f"; fi
  done
  run mkdir -p "$D/gatus/data" "$D/beszel/hub-data" "$D/beszel/agent-data" "$D/dozzle/data"
  run chown -R "$REMAP:$REMAP" "$D/gatus" "$D/beszel/hub-data" "$D/dozzle"
  run chown -R "$NOBODY:$NOBODY" "$D/beszel/agent-data"
}

# ---- env: .env from the example, values from the host -------------------------------------------------
envfile() {
  step "env: $D/.env (values never printed)"
  if [ ! -f "$D/.env" ]; then run install -m 600 -o "${ADMIN:-root}" "$SRC/.env.example" "$D/.env"; fi
  [ "$MODE" = dry ] && [ ! -f "$D/.env" ] && { note "values set after the copy"; return; }
  run chmod 600 "$D/.env"
  local js dns name
  js=$(ts_json)
  dns=$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null || true)
  name=$(printf '%s' "$js" | python3 -c 'import sys,json;print((json.load(sys.stdin)["Self"].get("DNSName") or "").rstrip("."))' 2>/dev/null || true)
  if [ -z "$(envval TS_TAILNET_DOMAIN)" ]; then
    if [ -n "$dns" ]; then setenv TS_TAILNET_DOMAIN "$dns"; else bad "TS_TAILNET_DOMAIN empty and Tailscale not up"; fi
  fi
  if [ -z "$(envval DOZZLE_HOSTNAME)" ] && [ -n "$name" ]; then setenv DOZZLE_HOSTNAME "$name"; fi
  if [ -z "$(envval HC_SECRET_KEY)" ]; then setenv HC_SECRET_KEY "$(openssl rand -hex 32)"; fi
  # Beszel agent key: derived from the hub's own key, so it always matches (no copy-paste)
  if [ -f "$D/beszel/hub-data/id_ed25519" ]; then
    local k; k=$(ssh-keygen -y -f "$D/beszel/hub-data/id_ed25519")
    if [ "$(envval BESZEL_HUB_PUBKEY)" != "$k" ]; then setenv BESZEL_HUB_PUBKEY "$k"; else ok "BESZEL_HUB_PUBKEY matches the hub"; fi
  else
    note "hub key not created yet: the agent starts on the next run, after the hub's first start"
  fi
}

# ---- up: start what can start ----------------------------------------------------------------------
up() {
  step "up: docker compose"
  if [ "$MODE" = dry ]; then echo "  + docker compose config --quiet && docker compose up -d"; return; fi
  dc config --quiet
  if [ -n "$(envval BESZEL_HUB_PUBKEY)" ]; then dc up -d
  else dc up -d socketproxy gatus beszel dozzle healthchecks; note "beszel-agent waits for the hub key: run this script again"; fi
}

# ---- serve: the UIs as Tailscale Services ------------------------------------------------------------
serve() {
  step "serve: Tailscale Services (auto-approved for tag:monitoring)"
  local s svc port
  for s in $SERVICES; do
    svc=${s%%:*}; port=${s##*:}
    run tailscale serve --bg --service="svc:$svc" --https=443 "127.0.0.1:$port" >/dev/null
    ok "svc:$svc -> 127.0.0.1:$port"
  done
}

# ---- verify ------------------------------------------------------------------------------------------
verify() {
  step "verify"
  local f s svc port k st appr
  for f in compose.yaml gatus/config/config.yaml; do
    cmp -s "$SRC/$f" "$D/$f" && ok "$f matches the checkout" || bad "$f differs from the checkout"
  done
  [ "$(stat -c %a "$D/.env" 2>/dev/null)" = 600 ] && ok ".env is 600" || bad ".env missing or not 600"
  for k in TS_TAILNET_DOMAIN DOZZLE_HOSTNAME HC_SECRET_KEY BESZEL_HUB_PUBKEY; do
    [ -n "$(envval "$k")" ] && ok "$k set" || bad "$k empty"
  done
  if [ -f "$D/beszel/hub-data/id_ed25519" ]; then
    [ "$(envval BESZEL_HUB_PUBKEY)" = "$(ssh-keygen -y -f "$D/beszel/hub-data/id_ed25519")" ] \
      && ok "Beszel agent key matches the hub" || bad "Beszel agent key doesn't match the hub (run without options)"
  fi
  [ "$(stat -c %u "$D/beszel/agent-data" 2>/dev/null)" = "$NOBODY" ] && ok "agent data owned $NOBODY" || bad "agent data not owned $NOBODY"
  [ "$(stat -c %u "$D/gatus/data" 2>/dev/null)" = "$REMAP" ] && ok "gatus data owned $REMAP" || bad "gatus data not owned $REMAP"
  for s in gatus beszel beszel-agent dozzle socketproxy healthchecks; do
    st=$(dc ps --format '{{.Status}}' "$s" 2>/dev/null | head -1 || true)
    case "$st" in
      *unhealthy*|"") bad "$s: ${st:-not running}" ;;
      Up*) ok "$s: $st" ;;
      *) bad "$s: $st" ;;
    esac
  done
  ss -ltn | grep '172.31.250.1:45876 ' >/dev/null && ok "agent listens on 172.31.250.1:45876" || bad "agent not listening on 172.31.250.1:45876"
  appr=$(ts_json | python3 -c 'import sys,json;h=json.load(sys.stdin)["Self"].get("CapMap",{}).get("service-host") or [{}];print(" ".join(h[0].keys()))' 2>/dev/null || true)
  for s in $SERVICES; do
    svc=${s%%:*}; port=${s##*:}
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/")" != 000 ] && ok "$svc answers on 127.0.0.1:$port" || bad "$svc not answering on 127.0.0.1:$port"
    case " $appr " in *" svc:$svc "*) ok "svc:$svc approved for this host" ;; *) bad "svc:$svc not approved (tag:monitoring? --serve, then check the console)" ;; esac
  done
}

case "$MODE" in
  apply|dry) files; envfile; up ;;
  serve) serve ;;
esac
[ "$MODE" = dry ] && { echo; echo "Dry run, nothing changed."; exit 0; }
verify
echo; [ "$FAIL" -eq 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
