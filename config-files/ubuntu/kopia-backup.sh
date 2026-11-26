#!/bin/bash
# kopia-backup.sh: back up a Docker host's state to the homenas Kopia server, append-only. Generic: what to
# back up, which compose stack to pause and the Kopia identity come from the host's .conf.
# DRAFT (kaywoz/home0ps#255, #404). Kopia runs as an installed binary, as root (reads every file). Works on
# any Ubuntu/Debian host or VM, with or without Docker (Docker is only used when STOP_COMPOSE is set).
#
#   sudo ./kopia-backup.sh --setup              once: install kopia (Kopia's signed APT repository), connect
#                                               (asks the Kopia user's password), write the systemd service +
#                                               timer, enable the timer
#   sudo ./kopia-backup.sh                      one backup now: pause the stack, snapshot each source, resume, ping
#   sudo ./kopia-backup.sh --test-append-only   snapshot an empty test folder, try to delete it: must fail
#   sudo ./kopia-backup.sh --verify             config, timer, each source's last snapshot under 26 h; exit 1 on a failure
#   sudo ./kopia-backup.sh --dry-run            show what --setup and a run would do
#
# Server side first (homenas, in the Kopia container; see the PR): user mover@<hostname>, ACLs enabled,
# that user APPEND on its own snapshots (no delete). Retention runs on the server, never here.
# File names (CLAUDE.md §8): what kaywoz writes is /etc/home0ps/kopia-backup.conf (root, 600):
#   KOPIA_URL=https://kopia.<tailnet>.ts.net     the svc:kopia URL
#   KOPIA_HOST=                                  optional: identity mover@<KOPIA_HOST>; default this host's short
#                                                hostname (data-moving accounts are mover@<hostname>, CLAUDE.md §8)
#   SOURCES="/srv/docker"                        absolute paths, space-separated; snapshotted under the same paths
#   STOP_COMPOSE=/srv/docker                     compose project to stop during the snapshot (SQLite etc.); empty = none
#   KOPIA_FINGERPRINT=                           only if svc:kopia is TCP passthrough (Kopia's own TLS)
#   HC_PING_URL=https://healthchecks.<tailnet>.ts.net/ping/<uuid>   optional; a bearer secret
#   ON_CALENDAR="*-*-* 02:47"                    optional systemd OnCalendar
# What the script generates goes to /var/lib/home0ps/kopia-backup/ (Kopia config + cache, root 700) and the
# systemd units home0ps-kopia-backup.{service,timer} (first line: GENERATED).
set -Eeuo pipefail
trap 'echo "kopia-backup.sh: failed on line $LINENO" >&2' ERR
export LC_ALL=C

MODE=run
case "${1:-}" in
  --setup) MODE=setup ;;
  --test-append-only) MODE=test ;;
  --verify) MODE=verify ;;
  --dry-run) MODE=dry ;;
  -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

CONF=/etc/home0ps/kopia-backup.conf
STATE=/var/lib/home0ps/kopia-backup
KEYRING=/etc/apt/keyrings/kopia-keyring.gpg
APT_LIST=/etc/apt/sources.list.d/kopia.list
KUSER=mover                             # data-moving accounts are always mover@<hostname> (kaywoz, 2026-11-26)
UNIT=home0ps-kopia-backup
TEST=/var/lib/home0ps/kopia-backup-test    # empty folder for --test-append-only
KOPIA_URL=""; KOPIA_HOST=""; SOURCES=""; STOP_COMPOSE=""; KOPIA_FINGERPRINT=""; HC_PING_URL=""
ON_CALENDAR="*-*-* 02:47"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
[ -n "$KOPIA_HOST" ] || KOPIA_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')   # read at run time, never in git

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }
ping_hc() { [ -n "$HC_PING_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_PING_URL$1" || true; }
# kopia ARGS...: the installed binary, as root, with config, cache and logs under $STATE
kopia() {
  KOPIA_CONFIG_PATH="$STATE/config/repository.config" KOPIA_CACHE_DIRECTORY="$STATE/cache" \
  KOPIA_LOG_DIR="$STATE/logs" KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=true KOPIA_CHECK_FOR_UPDATES=false \
    command kopia "$@"
}
# install: Kopia's APT repository (Installation docs), key downloaded to a temp file, checked, then dearmored
install_kopia() {
  step "install: kopia from Kopia's signed APT repository"
  if type -P kopia >/dev/null; then ok "kopia installed ($(command kopia --version 2>/dev/null | head -1))"; return; fi
  if [ "$MODE" = dry ]; then echo "  + key https://kopia.io/signing-key -> $KEYRING; $APT_LIST; apt-get install kopia"; return; fi
  local T; T=$(mktemp)
  curl -fsSL -m 30 https://kopia.io/signing-key -o "$T" && [ -s "$T" ] || { rm -f "$T"; bad "signing key download failed"; exit 1; }
  install -d -m 755 /etc/apt/keyrings
  gpg --dearmor < "$T" > "$T.gpg" && [ -s "$T.gpg" ] && install -m 644 "$T.gpg" "$KEYRING"; rm -f "$T" "$T.gpg"
  echo "  ..    key fingerprint (compare with Kopia's published key):"
  gpg --show-keys --with-fingerprint "$KEYRING" 2>/dev/null | sed -n 's/^ *\([0-9A-F ]\{40,\}\)$/        \1/p'
  echo "deb [signed-by=$KEYRING] http://packages.kopia.io/apt/ stable main" > "$APT_LIST"
  apt-get update -q -o Dir::Etc::sourcelist="$APT_LIST" -o Dir::Etc::sourceparts=- >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q kopia >/dev/null
  type -P kopia >/dev/null && ok "kopia installed ($(command kopia --version | head -1))" || { bad "kopia install failed"; exit 1; }
}
need_conf() {
  [ -r "$CONF" ] || { echo "Missing $CONF (root, 600): see the header." >&2; exit 1; }
  [ "$(stat -c %a "$CONF")" = 600 ] || { echo "$CONF must be mode 600." >&2; exit 1; }
  [[ "$KOPIA_URL" =~ ^https://[a-z0-9.-]+(:[0-9]+)?$ ]] || { echo "KOPIA_URL must be https://HOST[:PORT]" >&2; exit 1; }
  [[ "$KOPIA_HOST" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "KOPIA_HOST must be a lowercase host name" >&2; exit 1; }
  [ -n "$SOURCES" ] || { echo "SOURCES is empty" >&2; exit 1; }
  local p; for p in $SOURCES; do
    [[ "$p" == /* && "$p" != / ]] || { echo "SOURCES: absolute paths only, not /: $p" >&2; exit 1; }
    [ -d "$p" ] || { echo "SOURCES: $p doesn't exist" >&2; exit 1; }
  done
  [ -z "$STOP_COMPOSE" ] || [ -f "$STOP_COMPOSE/compose.yaml" ] || { echo "STOP_COMPOSE: no compose.yaml in $STOP_COMPOSE" >&2; exit 1; }
  [ -z "$STOP_COMPOSE" ] || command -v docker >/dev/null 2>&1 || { echo "STOP_COMPOSE set but Docker isn't installed" >&2; exit 1; }
}

setup() {
  need_conf
  step "state: $STATE (root, 700)"
  install_kopia
  run install -d -m 700 "$STATE" "$STATE/config" "$STATE/cache" "$STATE/logs" "$TEST"
  step "connect: $KUSER@$KOPIA_HOST -> $KOPIA_URL (asks for the Kopia user's password; persisted, 600)"
  local fp=(); [ -n "$KOPIA_FINGERPRINT" ] && fp=(--server-cert-fingerprint="$KOPIA_FINGERPRINT")
  if [ "$MODE" != dry ] && kopia repository status >/dev/null 2>&1; then ok "already connected"
  else run kopia repository connect server --url="$KOPIA_URL" "${fp[@]}" \
         --override-username="$KUSER" --override-hostname="$KOPIA_HOST"; fi
  step "systemd: $UNIT.service + .timer (daily, catches up after downtime)"
  local self; self=$(readlink -f "$0")
  if [ "$MODE" = dry ]; then echo "  + write /etc/systemd/system/$UNIT.{service,timer}; enable --now $UNIT.timer"; return; fi
  cat > "/etc/systemd/system/$UNIT.service" <<EOF
# GENERATED by $self: don't edit
[Unit]
Description=Back up this host to the homenas Kopia server (kopia-backup.sh)
Wants=network-online.target
After=network-online.target tailscaled.service docker.service
[Service]
Type=oneshot
ExecStart=$self
EOF
  cat > "/etc/systemd/system/$UNIT.timer" <<EOF
# GENERATED by $self: don't edit
[Unit]
Description=Daily Kopia backup
[Timer]
OnCalendar=$ON_CALENDAR
RandomizedDelaySec=15m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now "$UNIT.timer" >/dev/null
  ok "timer enabled: $(systemctl show -p NextElapseUSecRealtime --value "$UNIT.timer" 2>/dev/null)"
}

backup() {
  need_conf
  step "backup: $SOURCES"
  ping_hc /start
  if [ "$MODE" = dry ]; then
    [ -n "$STOP_COMPOSE" ] && echo "  + docker compose stop ($STOP_COMPOSE)"
    echo "  + kopia snapshot create $SOURCES"
    [ -n "$STOP_COMPOSE" ] && echo "  + docker compose start ($STOP_COMPOSE)"
    return
  fi
  local rc=0 p
  # Databases (SQLite and the like) are only consistent with the stack stopped: seconds a night.
  if [ -n "$STOP_COMPOSE" ]; then (cd "$STOP_COMPOSE" && docker compose stop >/dev/null) || rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    for p in $SOURCES; do kopia snapshot create "$p" --description="kopia-backup $(date -u +%F)" || rc=$?; done
  fi
  if [ -n "$STOP_COMPOSE" ]; then (cd "$STOP_COMPOSE" && docker compose start >/dev/null) || rc=$?; fi
  if [ "$rc" -eq 0 ]; then ok "snapshots done${STOP_COMPOSE:+, stack started}"; ping_hc ""
  else bad "backup failed (exit $rc)${STOP_COMPOSE:+; stack start attempted}"; ping_hc /fail; exit 1; fi
}

test_append_only() {
  need_conf
  step "append-only test: snapshot an empty folder, then try to delete it"
  install -d -m 700 "$TEST"
  kopia snapshot create "$TEST" --description="append-only test" >/dev/null
  local id
  id=$(kopia snapshot list "$TEST" --json | python3 -c 'import sys,json;l=json.load(sys.stdin);print(l[-1]["id"] if l else "")')
  [ -n "$id" ] || { bad "test snapshot not found"; return; }
  if kopia snapshot delete "$id" --delete >/dev/null 2>&1; then
    bad "DELETE WAS ALLOWED: the server ACL isn't append-only for $KUSER@$KOPIA_HOST (only the test snapshot was deleted)"
  else ok "delete refused: append-only works"; fi
}

verify() {
  step "verify"
  [ -r "$CONF" ] && [ "$(stat -c %a "$CONF")" = 600 ] && ok "$CONF present, 600" || bad "$CONF missing or not 600"
  [ "$(stat -c %a "$STATE" 2>/dev/null)" = 700 ] && ok "$STATE is 700" || bad "$STATE missing or not 700"
  type -P kopia >/dev/null && ok "kopia binary present" || { bad "kopia not installed (run --setup)"; return; }
  kopia repository status >/dev/null 2>&1 && ok "connected to the repository server" || bad "not connected (run --setup)"
  systemctl is-enabled --quiet "$UNIT.timer" 2>/dev/null && ok "$UNIT.timer enabled" || bad "$UNIT.timer not enabled"
  [ "$MODE" = setup ] && { note "first snapshot: run without options, or wait for the timer"; return; }
  local age p
  for p in $SOURCES; do
    age=$(kopia snapshot list "$p" --json 2>/dev/null | python3 -c '
import sys,json,datetime
l=json.load(sys.stdin)
if not l: print(""); sys.exit()
import re
t=re.sub(r"\.(\d{1,6})\d*", lambda m: "."+m.group(1).ljust(6,"0"), l[-1]["endTime"]).replace("Z","+00:00")
print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(t)).total_seconds()//3600))' 2>/dev/null || true)
    if [ -z "$age" ]; then bad "$p: no snapshot yet"
    elif [ "$age" -le 26 ]; then ok "$p: last snapshot ${age} h ago"
    else bad "$p: last snapshot ${age} h ago (over 26 h)"; fi
  done
}

case "$MODE" in
  setup) setup; verify ;;
  dry) setup; backup; echo; echo "Dry run, nothing changed."; exit 0 ;;
  run) backup ;;
  test) test_append_only ;;
  verify) verify ;;
esac
echo; [ "$FAIL" -eq 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
