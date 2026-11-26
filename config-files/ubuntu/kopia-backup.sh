#!/bin/bash
# kopia-backup.sh: append-only backups of a host to the homenas Kopia server, set up end to end by one script.
# Clients: any Ubuntu/Debian host or VM, with or without Docker. Server: the homenas Kopia container.
# The Kopia identity is always mover@<hostname> (CLAUDE.md §8 Names); the host name is read at run time.
#
# On the homenas, once per client (root; the Kopia repository must exist):
#   ./kopia-backup.sh --server          asks the client's host name; adds or resets user mover@<host> (asks its
#                                       password), enables ACLs, removes the default FULL snapshot rule, adds
#                                       mover@* APPEND (no delete), restarts the server and checks the rules
# On each client (root):
#   ./kopia-backup.sh --setup           creates /etc/home0ps and the state folders, writes the .conf from prompts
#                                       (defaults read from the host), installs kopia, connects (asks mover's
#                                       password), installs the daily systemd timer, then offers the append-only
#                                       test and a first backup
#   ./kopia-backup.sh                   one backup now: pause the stack, snapshot each source, resume, ping
#   ./kopia-backup.sh --test-append-only   snapshot an empty test folder, try to delete it: must be refused
#   ./kopia-backup.sh --verify          config, timer, each source's last snapshot under 26 h; exit 1 on a failure
#   ./kopia-backup.sh --dry-run         show what --setup and a run would do, change nothing
# Retention runs on the server, never here: an append-only client can't delete.
#
# File names (CLAUDE.md §8): settings /etc/home0ps/kopia-backup.conf (root, 600; written by --setup, edit freely):
#   KOPIA_URL=https://kopia.<tailnet>.ts.net:443   svc:kopia; Kopia's gRPC client needs the port (:443 added)
#   SOURCES="/srv/docker"                          absolute paths, space-separated
#   STOP_COMPOSE=/srv/docker                       compose project stopped during the snapshot; empty = none
#   HC_PING_URL=                                   optional Healthchecks ping URL (a bearer secret)
#   ON_CALENDAR="*-*-* 02:47"                      systemd OnCalendar
#   KOPIA_HOST=                                    optional override of the host name in mover@<host>
#   KOPIA_FINGERPRINT=                             only if svc:kopia is TCP passthrough (Kopia's own TLS)
# Generated: /var/lib/home0ps/kopia-backup/ (Kopia config, cache, logs; root 700) and the systemd units
# home0ps-kopia-backup.{service,timer} (first line: GENERATED). The timer is the scheduler (no cron entry).
# Server mode setting: KOPIA_CONTAINER=kr-ccp-kopia-0101.
set -Eeuo pipefail
trap 'echo "kopia-backup.sh: failed on line $LINENO" >&2' ERR
export LC_ALL=C

MODE=run
case "${1:-}" in
  --setup) MODE=setup ;;
  --server) MODE=server ;;
  --test-append-only) MODE=test ;;
  --verify) MODE=verify ;;
  --dry-run) MODE=dry ;;
  -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

CONF=/etc/home0ps/kopia-backup.conf
STATE=/var/lib/home0ps/kopia-backup
KEYRING=/etc/apt/keyrings/kopia-keyring.gpg
APT_LIST=/etc/apt/sources.list.d/kopia.list
KUSER=mover                             # data-moving accounts are always mover@<hostname> (kaywoz, 2026-11-26)
UNIT=home0ps-kopia-backup
TEST=/var/lib/home0ps/kopia-backup-test    # empty folder for --test-append-only
KOPIA_CONTAINER="${KOPIA_CONTAINER:-kr-ccp-kopia-0101}"
KOPIA_URL=""; KOPIA_HOST=""; SOURCES=""; STOP_COMPOSE=""; KOPIA_FINGERPRINT=""; HC_PING_URL=""
ON_CALENDAR="*-*-* 02:47"
load_conf() {
  # shellcheck disable=SC1090
  if [ -r "$CONF" ]; then . "$CONF"; fi
  [ -n "$KOPIA_HOST" ] || KOPIA_HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')   # read at run time, never in git
}
load_conf

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }
have_tty() { { : </dev/tty; } 2>/dev/null; }
# ask VAR "question" "default": "-" answers "none"
ask() {
  local __v=""
  read -r -p "  $2 [${3:--}]: " __v </dev/tty || true
  [ -n "$__v" ] || __v=$3
  [ "$__v" = "-" ] && __v=""
  printf -v "$1" '%s' "$__v"
}
ask_secret() { local __v=""; read -rs -p "  $2: " __v </dev/tty || true; echo; printf -v "$1" '%s' "$__v"; }
yesno() { local __a=""; read -r -p "  $1 [${2}]: " __a </dev/tty || true; [[ "${__a:-$2}" =~ ^[Yy] ]]; }
safe() { [[ "$1" != *[\"\$\`\\]* ]] || { echo "Not allowed in a value: \" \$ \` \\ ($1)" >&2; exit 1; }; }
ping_hc() { [ -n "$HC_PING_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_PING_URL$1" || true; }
# kopia ARGS...: the installed binary, as root, with config, cache and logs under $STATE
kopia() {
  KOPIA_CONFIG_PATH="$STATE/config/repository.config" KOPIA_CACHE_DIRECTORY="$STATE/cache" \
  KOPIA_LOG_DIR="$STATE/logs" KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=true KOPIA_CHECK_FOR_UPDATES=false \
    command kopia "$@"
}

# ==== client: settings ===============================================================================
write_conf() {
  step "settings: $CONF (root, 600)"
  run install -d -m 700 "$(dirname "$CONF")"
  if [ -f "$CONF" ]; then
    run chmod 600 "$CONF"; ok "$CONF present: kept (edit it, or delete it to be asked again)"; return
  fi
  local dns url src stop hc="" cal="$ON_CALENDAR"
  dns=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null || true)
  url="https://kopia.${dns:-TAILNET.ts.net}:443"
  src=""; [ -d /srv/docker ] && src=/srv/docker
  stop=""; [ -f /srv/docker/compose.yaml ] && command -v docker >/dev/null 2>&1 && stop=/srv/docker
  if have_tty && [ "$MODE" != dry ]; then
    note "Enter keeps the [default]; - means none"
    ask url "Kopia server URL" "$url"
    ask src "Folders to back up (absolute, space-separated)" "$src"
    ask stop "Compose project to stop during the snapshot" "$stop"
    ask_secret hc "Healthchecks ping URL (optional, hidden; Enter = none)"
    ask cal "Schedule (systemd OnCalendar)" "$cal"
  else
    note "no terminal: writing the defaults; check $CONF before the first run"
  fi
  local v; for v in "$url" "$src" "$stop" "$hc" "$cal"; do safe "$v"; done
  if [ "$MODE" = dry ]; then echo "  + write $CONF: KOPIA_URL=$url SOURCES=\"$src\" STOP_COMPOSE=$stop ON_CALENDAR=\"$cal\""; return; fi
  ( umask 077
    cat > "$CONF" <<EOF
# kopia-backup.conf: written by kopia-backup.sh --setup on $(date -u +%F); edit freely (root, 600).
# Settings are explained in the script's header (config-files/ubuntu/kopia-backup.sh).
KOPIA_URL=$url
SOURCES="$src"
STOP_COMPOSE=$stop
HC_PING_URL=$hc
ON_CALENDAR="$cal"
#KOPIA_HOST=           default: this host's short name -> identity mover@<hostname>
#KOPIA_FINGERPRINT=    only if svc:kopia is served as TCP passthrough
EOF
  )
  ok "$CONF written (600)"
  load_conf
}
need_conf() {
  [ -r "$CONF" ] || { echo "Missing $CONF: run --setup." >&2; exit 1; }
  [ "$(stat -c %a "$CONF")" = 600 ] || { echo "$CONF must be mode 600." >&2; exit 1; }
  [[ "$KOPIA_URL" =~ ^https://[a-z0-9.-]+(:[0-9]+)?$ ]] || { echo "KOPIA_URL must be https://HOST[:PORT] (in $CONF)" >&2; exit 1; }
  [[ "$KOPIA_URL" != *TAILNET* ]] || { echo "KOPIA_URL still has the TAILNET placeholder (in $CONF)" >&2; exit 1; }
  # Kopia's gRPC client builds "host:port" and fails on an empty port ("missing port after port-separator")
  [[ "$KOPIA_URL" =~ :[0-9]+$ ]] || KOPIA_URL="$KOPIA_URL:443"
  [[ "$KOPIA_HOST" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "KOPIA_HOST must be a lowercase host name" >&2; exit 1; }
  [ -n "$SOURCES" ] || { echo "SOURCES is empty (in $CONF)" >&2; exit 1; }
  local p; for p in $SOURCES; do
    [[ "$p" == /* && "$p" != / ]] || { echo "SOURCES: absolute paths only, not /: $p" >&2; exit 1; }
    [ -d "$p" ] || { echo "SOURCES: $p doesn't exist" >&2; exit 1; }
  done
  [ -z "$STOP_COMPOSE" ] || [ -f "$STOP_COMPOSE/compose.yaml" ] || { echo "STOP_COMPOSE: no compose.yaml in $STOP_COMPOSE" >&2; exit 1; }
  [ -z "$STOP_COMPOSE" ] || command -v docker >/dev/null 2>&1 || { echo "STOP_COMPOSE set but Docker isn't installed" >&2; exit 1; }
}

# ==== client: install, connect, schedule ==============================================================
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

setup() {
  write_conf
  [ "$MODE" = dry ] && [ ! -f "$CONF" ] || need_conf
  step "state: $STATE, $TEST (root, 700)"
  run install -d -m 700 "$(dirname "$STATE")" "$STATE" "$STATE/config" "$STATE/cache" "$STATE/logs" "$TEST"
  install_kopia
  step "connect: $KUSER@$KOPIA_HOST -> ${KOPIA_URL:-?} (the password of $KUSER@$KOPIA_HOST, not the repository's)"
  local fp=(); [ -n "$KOPIA_FINGERPRINT" ] && fp=(--server-cert-fingerprint="$KOPIA_FINGERPRINT")
  if [ "$MODE" != dry ] && kopia repository status >/dev/null 2>&1; then ok "already connected"
  else
    note "the user must exist on the server first: ./kopia-backup.sh --server on the homenas"
    run kopia repository connect server --url="$KOPIA_URL" "${fp[@]}" \
      --override-username="$KUSER" --override-hostname="$KOPIA_HOST"
  fi
  step "schedule: $UNIT.service + .timer ($ON_CALENDAR, catches up after downtime)"
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
  ok "timer enabled: next run $(systemctl show -p NextElapseUSecRealtime --value "$UNIT.timer" 2>/dev/null)"
  if have_tty; then
    if yesno "Run the append-only test now? (leaves one empty test snapshot)" Y; then test_append_only; fi
    if yesno "Run the first backup now?" Y; then backup; fi
  fi
}

backup() {
  [ "$MODE" = dry ] && [ ! -f "$CONF" ] || need_conf
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
    bad "DELETE WAS ALLOWED: the server ACL isn't append-only for $KUSER@$KOPIA_HOST (run --server on the homenas)"
  else ok "delete refused: append-only works"; fi
}

verify() {
  step "verify"
  [ -r "$CONF" ] && [ "$(stat -c %a "$CONF")" = 600 ] && ok "$CONF present, 600" || bad "$CONF missing or not 600"
  [ "$(stat -c %a "$STATE" 2>/dev/null)" = 700 ] && ok "$STATE is 700" || bad "$STATE missing or not 700"
  type -P kopia >/dev/null && ok "kopia binary present" || { bad "kopia not installed (run --setup)"; return; }
  kopia repository status >/dev/null 2>&1 && ok "connected to the repository server" || bad "not connected (run --setup)"
  systemctl is-enabled --quiet "$UNIT.timer" 2>/dev/null && ok "$UNIT.timer enabled" || bad "$UNIT.timer not enabled"
  local age p
  for p in $SOURCES; do
    age=$(kopia snapshot list "$p" --json 2>/dev/null | python3 -c '
import sys,json,datetime,re
l=json.load(sys.stdin)
if not l: print(""); sys.exit()
t=re.sub(r"\.(\d{1,6})\d*", lambda m: "."+m.group(1).ljust(6,"0"), l[-1]["endTime"]).replace("Z","+00:00")
print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(t)).total_seconds()//3600))' 2>/dev/null || true)
    if [ -z "$age" ]; then
      if [ "$MODE" = setup ]; then note "$p: no snapshot yet (the timer takes the first)"; else bad "$p: no snapshot yet"; fi
    elif [ "$age" -le 26 ]; then ok "$p: last snapshot ${age} h ago"
    else bad "$p: last snapshot ${age} h ago (over 26 h)"; fi
  done
}

# ==== server (homenas): user and append-only ACL ======================================================
kx()  { docker exec "$KOPIA_CONTAINER" kopia "$@"; }
kxi() { docker exec -it "$KOPIA_CONTAINER" kopia "$@"; }
acl_list() { kx server acl list 2>/dev/null || true; }
server_setup() {
  step "server: Kopia repository server in container $KOPIA_CONTAINER"
  [ "$(docker inspect -f '{{.State.Running}}' "$KOPIA_CONTAINER" 2>/dev/null)" = true ] \
    || { bad "$KOPIA_CONTAINER isn't running"; exit 1; }
  kx repository status >/dev/null 2>&1 \
    || { bad "no repository connected in the container: create it first (storage-stack.sh next steps)"; exit 1; }
  ok "repository connected"
  have_tty || { echo "--server asks for the client's host name and password: run it in a terminal." >&2; exit 1; }
  local host="" user
  ask host "Client host name (its \`hostname -s\`)" ""
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [[ "$host" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "Not a host name: $host" >&2; exit 1; }
  user="$KUSER@$host"

  step "user: $user"
  if kx server user list 2>/dev/null | grep -Fx "$user" >/dev/null; then
    ok "$user exists"
    if yesno "Set a new password for $user?" N; then run kxi server user set "$user" --ask-password; fi
  else
    run kxi server user add "$user" --ask-password
  fi

  step "ACL: only $KUSER@* may write snapshots, append-only (no delete)"
  if ! acl_list | grep 'access:' >/dev/null; then run kx server acl enable; fi
  local id
  for id in $(acl_list | awk '/user:\*@\* access:FULL target:type=snapshot/ {sub("^id:","",$1); print $1}'); do
    note "removing the default FULL snapshot rule $id"
    run kx server acl remove "$id" --delete
  done
  if acl_list | grep -F "user:$KUSER@* access:APPEND target:type=snapshot" >/dev/null; then ok "$KUSER@* APPEND rule present"
  else run kx server acl add --user "$KUSER@*" --access APPEND --target type=snapshot,username=OWN_USER,hostname=OWN_HOST; fi

  step "restart: the server loads users and ACLs"
  [ "$MODE" = dry ] || { docker restart "$KOPIA_CONTAINER" >/dev/null; sleep 15; }
  local acl; acl=$(acl_list)
  printf '%s\n' "$acl" | grep 'access:FULL target:type=snapshot' >/dev/null && bad "a FULL snapshot rule is still there" || ok "no FULL snapshot rule"
  printf '%s\n' "$acl" | grep -F "user:$KUSER@* access:APPEND target:type=snapshot" >/dev/null && ok "$KUSER@* APPEND rule active" || bad "$KUSER@* APPEND rule missing"
  kx server user list 2>/dev/null | grep -Fx "$user" >/dev/null && ok "$user listed" || bad "$user not listed"
  note "next, on the client as root: ./kopia-backup.sh --setup (the password just set for $user)"
}

case "$MODE" in
  setup) setup; verify ;;
  server) server_setup ;;
  dry) setup; backup; echo; echo "Dry run, nothing changed."; exit 0 ;;
  run) backup ;;
  test) test_append_only ;;
  verify) verify ;;
esac
echo; [ "$FAIL" -eq 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
