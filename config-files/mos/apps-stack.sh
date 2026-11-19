#!/bin/bash
# apps-stack.sh: prepare, serve and verify phase 1 of the homenas apps stack
# (docker-compose/homenas/apps/, kaywoz/home0ps#320).
#
# Phase 1 = mediasort, CannonCommander, Atuin, HedgeDoc, Filestash, RackPeek (COMPOSE_PROFILES empty).
# Run as root on the homenas. Everything lives with MOS's Docker data, on the pool, not on the boot stick:
# it only works once Docker and the pool are up anyway. It gets its own folder in appdata, next to the app
# folders and MOS's compose_<stack> folders. H = <appdata>/home0ps:
#   mkdir -p /var/mergerfs/merger-nvme/disk1/mos-docker/appdata/home0ps
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/mos/apps-stack.sh \
#     -o /var/mergerfs/merger-nvme/disk1/mos-docker/appdata/home0ps/apps-stack.sh
#
#   bash $H/apps-stack.sh --dry-run   show what would change
#   bash $H/apps-stack.sh             folders, secrets, image checks, the stack's .env
#                                     and compose.yaml to paste into the MOS UI
#   bash $H/apps-stack.sh --serve     the Tailscale Services (after the stack runs)
#   bash $H/apps-stack.sh --verify    check everything, change nothing; exit 1 on a failure
#
# Re-runnable: existing secrets and configs are kept, never overwritten. Nothing prints a secret.
# The MOS UI steps (create the stack, autostart, start) and the first logins stay manual; the default
# mode prints them at the end.
#
# Settings file (host-local, not in git): $H/apps-stack.env
# (override with APPS_STACK_ENV=<file>; template: config-files/mos/apps-stack.env.example):
#   SHARE_USER=              the Samba-only data user CannonCommander runs as (README A-Q2) [required]
#   SHARE_DATA=/mnt/user/1.data   SHARE_TMP=/mnt/user/tmp   what CannonCommander serves
#   MOVER_TOKEN=/boot/config/home0ps/media-sort.token   the mover's copy of mediasort's bearer token
#                            (config-files/mos/media-sort.env.example TOKEN_FILE)
# Paths (environment, rarely changed): MOS_DOCKER=/var/mergerfs/merger-nvme/disk1/mos-docker (MOS's Docker
# folder on the disk itself: Docker's own files stay outside mergerfs, never the /mnt/merger-* pool mount;
# service data such as SHARE_DATA goes through mergerfs; as in docker.json); appdata is $MOS_DOCKER/appdata; the rendered .env and compose.yaml go to $H/apps-stack/.
#   REPO_RAW=https://raw.githubusercontent.com/kaywoz/home0ps/main
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MOS_DOCKER="${MOS_DOCKER:-/var/mergerfs/merger-nvme/disk1/mos-docker}"
case "$MOS_DOCKER" in /mnt/merger*) echo "MOS_DOCKER is the mergerfs mount ($MOS_DOCKER): use the disk path, e.g. /var/mergerfs/merger-nvme/disk1/mos-docker" >&2; exit 1 ;; esac
H="$MOS_DOCKER/appdata/home0ps"
ENV_FILE="${APPS_STACK_ENV:-$H/apps-stack.env}"
MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --serve) MODE=serve ;;
  --verify) MODE=verify ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
SHARE_USER="${SHARE_USER:-}"
SHARE_DATA="${SHARE_DATA:-/mnt/user/1.data}"; SHARE_TMP="${SHARE_TMP:-/mnt/user/tmp}"
MOVER_TOKEN="${MOVER_TOKEN:-/boot/config/home0ps/media-sort.token}"
A="$MOS_DOCKER/appdata"
OUT_DIR="$H/apps-stack"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kaywoz/home0ps/main}"

# Phase-1 Services: name port (127.0.0.1). mediasort has none: the mover calls 127.0.0.1:8089.
SERVICES="cannoncommander:8080 atuin:8888 hedgedoc:3000 filestash:8334 rackpeek:8081"
CONTAINERS="kr-ccp-mediasort-0201 kr-ccp-cannoncommander-0101 kr-ccp-atuin-0101 kr-ccp-hedgedoc-0101 kr-ccp-filestash-0101 kr-ccp-rackpeek-0101"

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }

need_share_user() {
  [ -n "$SHARE_USER" ] || { echo "SHARE_USER is not set (in $ENV_FILE)." >&2; exit 1; }
  SHARE_UID=$(id -u "$SHARE_USER") && SHARE_GID=$(id -g "$SHARE_USER") \
    || { echo "SHARE_USER '$SHARE_USER' doesn't exist on this host." >&2; exit 1; }
}

# dir <path> <uid> <gid>: create (700) or fix the owner
dir() {
  if [ -d "$1" ]; then
    [ "$(stat -c '%u:%g' "$1")" = "$2:$3" ] && return 0
    note "re-own $1 to $2:$3"; run chown "$2:$3" "$1"
  else
    note "create $1 ($2:$3, 700)"; run install -d -m 700 -o "$2" -g "$3" "$1"
  fi
}

# check_file <path> <uid>: exists, owned by uid, mode 600
check_file() {
  if [ ! -f "$1" ]; then bad "$1 missing"; return; fi
  local m; m=$(stat -c '%u %a' "$1")
  [ "$m" = "$2 600" ] && ok "$1 ($2, 600)" || bad "$1 is '$m', expected '$2 600'"
}

# prompt_secret <name> <label>: ask for mediasort's secret file <name> once, hidden; kept if present
prompt_secret() {
  local f="$A/mediasort/secrets/$1" v
  if [ -f "$f" ]; then ok "$1 present (kept)"; return; fi
  if [ "$MODE" = dry ]; then note "would ask for $2"; return; fi
  read -rs -p "  $2: " v < /dev/tty; echo
  [ -n "$v" ] || { echo "Empty: $1 not written." >&2; exit 1; }
  (umask 077; printf '%s' "$v" > "$f"); unset v
  chown 2104:2104 "$f"; ok "$1 written (600, 2104)"
}

image_uid() {   # Filestash runs as its image's own user (README A-Q10)
  docker run --rm --entrypoint id machines/filestash:latest 2>/dev/null | sed -n 's/^uid=\([0-9]*\).* gid=\([0-9]*\).*/\1 \2/p'
}

tailnet() {     # MagicDNS name without .ts.net, for HedgeDoc's CMD_DOMAIN
  tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["MagicDNSSuffix"].removesuffix(".ts.net"))'
}

# ---- prepare (default and --dry-run) ------------------------------------------------------
prepare() {
  need_share_user
  command -v docker >/dev/null || { echo "docker not found: start Docker from the MOS UI first." >&2; exit 1; }
  [ -d "$A" ] || { echo "APPDATA $A doesn't exist." >&2; exit 1; }

  step "image checks (README 'Unverified')"
  local fs fs_uid fs_gid rp
  fs=$(image_uid); fs_uid=${fs% *}; fs_gid=${fs#* }
  [ -n "$fs" ] || { echo "Couldn't read Filestash's uid (docker run machines/filestash)." >&2; exit 1; }
  ok "Filestash runs as $fs_uid:$fs_gid"
  rp=$(docker run --rm --entrypoint env aptacode/rackpeek:latest 2>/dev/null | sed -n 's/^ASPNETCORE_HTTP_PORTS=//p')
  if [ "$rp" = 8080 ]; then ok "RackPeek listens on 8080 (as compose.yaml maps)"
  else echo "RackPeek's container port is '${rp:-unknown}', compose.yaml expects 8080: fix compose.yaml first." >&2; exit 1; fi

  step "folders"
  dir "$A/mediasort" 2104 2104;          dir "$A/mediasort/secrets" 2104 2104
  dir "$A/atuin" 2121 2121;              dir "$A/atuin/config" 2121 2121
  dir "$A/hedgedoc" 2123 2123;           dir "$A/hedgedoc/db" 2123 2123
  dir "$A/hedgedoc/uploads" 2123 2123;   dir "$A/hedgedoc/secrets" 2123 2123
  dir "$A/rackpeek" 1654 1654;           dir "$A/rackpeek/config" 1654 1654
  dir "$A/cannoncommander" "$SHARE_UID" "$SHARE_GID"; dir "$A/cannoncommander/cache" "$SHARE_UID" "$SHARE_GID"
  dir "$A/filestash" "$fs_uid" "$fs_gid"; dir "$A/filestash/state" "$fs_uid" "$fs_gid"

  step "mediasort secrets (token, tmdb, llm)"
  local ms="$A/mediasort/secrets"
  # token: the bearer key the mover sends. Reuse the mover's copy if this host has one, else generate a
  # new one and write both copies, so they match.
  if [ -f "$ms/token" ]; then ok "token present (kept)"
  elif [ -s "$MOVER_TOKEN" ]; then
    note "token: copy the mover's ($MOVER_TOKEN)"
    run install -m 600 -o 2104 -g 2104 "$MOVER_TOKEN" "$ms/token"
  else
    note "token: generate, also write the mover's copy ($MOVER_TOKEN)"
    if [ "$MODE" != dry ]; then
      install -d -m 700 "$(dirname "$MOVER_TOKEN")"
      (umask 077; openssl rand -hex 32 | tr -d '\n' > "$ms/token")
      install -m 600 "$ms/token" "$MOVER_TOKEN"
      chown 2104:2104 "$ms/token"
    fi
  fi
  # tmdb and llm: entered here, never echoed (the apps VM that held them is gone)
  prompt_secret tmdb "TMDB API Read Access Token (themoviedb.org: account settings -> API)"
  prompt_secret llm  "LLM provider API key (Anthropic by default; a new key with a spend limit)"

  step "HedgeDoc session secret"
  if [ -f "$A/hedgedoc/secrets/session_secret" ]; then ok "present (kept)"
  else
    note "generate $A/hedgedoc/secrets/session_secret"
    if [ "$MODE" != dry ]; then
      (umask 077; openssl rand -hex 32 | tr -d '\n' > "$A/hedgedoc/secrets/session_secret")
      chown 2123:2123 "$A/hedgedoc/secrets/session_secret"
    fi
  fi

  step "CannonCommander config.yaml (admin password)"
  if [ -f "$A/cannoncommander/config.yaml" ]; then ok "present (kept; change the password there, it's reset at every start)"
  elif [ "$MODE" = dry ]; then note "would ask for the admin password and write $A/cannoncommander/config.yaml"
  else
    local pw pw2
    read -rs -p "  CannonCommander admin password (12+ characters, no \" or \\): " pw < /dev/tty; echo
    read -rs -p "  again: " pw2 < /dev/tty; echo
    [ "$pw" = "$pw2" ] || { echo "Passwords differ." >&2; exit 1; }
    [ "${#pw}" -ge 12 ] || { echo "Shorter than 12 characters." >&2; exit 1; }
    case "$pw" in *\"*|*\\*) echo "No \" or \\ in the password." >&2; exit 1 ;; esac
    # upstream _docker/config.yaml, port 8080, no /remotes source (A-Q2), admin password set
    (umask 077; cat > "$A/cannoncommander/config.yaml" <<EOF
http:
  port: 8080
  baseURL: "/"
server:
  cacheDir: "/config/cache"
  logging:
    - levels: "info|error|warning"
  sources:
    - path: "/mnt/user"
      name: "Shares"
auth:
  methods:
    noauth: false
    password:
      enabled: true
      adminUsername: "admin"
      adminPassword: "$pw"
      minLength: 12
EOF
)
    unset pw pw2
    chown "$SHARE_UID:$SHARE_GID" "$A/cannoncommander/config.yaml"
    ok "written (600, $SHARE_UID:$SHARE_GID)"
  fi

  step "the stack's .env and compose.yaml (to paste into the MOS UI)"
  local tn render atuin_open=false
  tn=$(tailnet); render=$(getent group render | cut -d: -f3)
  [ -n "$tn" ] || { echo "Couldn't read the tailnet name (tailscale status)." >&2; exit 1; }
  [ -n "$render" ] || { echo "No 'render' group on this host." >&2; exit 1; }
  [ -f "$A/atuin/config/atuin.db" ] || atuin_open=true
  run install -d -m 700 "$OUT_DIR"
  if [ "$MODE" != dry ]; then
    curl -fsSL "$REPO_RAW/docker-compose/homenas/apps/compose.yaml" -o "$OUT_DIR/compose.yaml"
    # No secrets in this file. Keys for the apps that stay off (paperless, immich, archivers) get
    # placeholders: Compose interpolates the whole file, but their networks and secrets aren't created.
    (umask 077; cat > "$OUT_DIR/apps.env" <<EOF
APPDATA=$A
SHARE_DATA=$SHARE_DATA
SHARE_TMP=$SHARE_TMP
SHARE_UID=$SHARE_UID
SHARE_GID=$SHARE_GID
TAILNET=$tn
RENDER_GID=$render
COMPOSE_PROFILES=
ATUIN_OPEN_REGISTRATION=$atuin_open
# phase 2+ (off): placeholders until their profile is switched on
PAPERLESS_URL=https://paperless.$tn.ts.net
PHOTOS=$A/unused/photos
PHOTOS_LIBRARY=$A/unused/photos-library
VLAN31_PARENT=unused.31
VLAN31_SUBNET=192.0.2.0/24
VLAN31_GATEWAY=192.0.2.1
VLAN31_RANGE=192.0.2.240/28
ARCHIVEBOX_IP=192.0.2.241
WARRIOR_IP=192.0.2.242
EOF
)
    ( cd "$OUT_DIR" && docker compose -f compose.yaml --env-file apps.env config --quiet ) \
      && ok "rendered and validated: $OUT_DIR/compose.yaml, $OUT_DIR/apps.env" \
      || bad "docker compose config failed on the rendered files"
    local services; services=$(cd "$OUT_DIR" && docker compose -f compose.yaml --env-file apps.env config --services | sort | tr '\n' ' ')
    [ "$services" = "atuin cannoncommander filestash hedgedoc mediasort rackpeek " ] \
      && ok "phase 1 services only: $services" || bad "unexpected services: $services"
  else
    note "would fetch compose.yaml from $REPO_RAW and render $OUT_DIR/apps.env (ATUIN_OPEN_REGISTRATION=$atuin_open)"
  fi

  [ "$MODE" = dry ] && return 0
  cat <<MSG

Next, in the MOS UI:
  1. Docker -> Stacks -> new stack "apps": paste $OUT_DIR/compose.yaml and $OUT_DIR/apps.env
  2. Autostart on, then start it.
  3. bash $0 --serve
  4. First logins, right away:
     - Filestash: https://filestash.$tn.ts.net/admin/setup -> set the admin password (open until you do)
     - Atuin: atuin register against https://atuin.$tn.ts.net, then re-run this script
       (it renders ATUIN_OPEN_REGISTRATION=false once atuin.db exists), paste the new .env, restart the stack
     - HedgeDoc: docker exec -it kr-ccp-hedgedoc-0101 bin/manage_users --add <your login email>
     - CannonCommander: sign in as admin with the password you just set
  5. bash $0 --verify
MSG
}

# ---- --serve ------------------------------------------------------------------------------
serve() {
  local s name port
  for s in $SERVICES; do
    name=${s%%:*}; port=${s##*:}
    step "svc:$name -> 127.0.0.1:$port"
    tailscale serve --service="svc:$name" --https=443 "127.0.0.1:$port"   # same form as the other Services in this repo
  done
  echo; tailscale serve status
}

# ---- --verify -----------------------------------------------------------------------------
verify() {
  need_share_user
  step "secret and config files"
  check_file "$A/mediasort/secrets/token" 2104
  check_file "$A/mediasort/secrets/tmdb" 2104
  check_file "$A/mediasort/secrets/llm" 2104
  check_file "$A/hedgedoc/secrets/session_secret" 2123
  check_file "$A/cannoncommander/config.yaml" "$SHARE_UID"

  step "containers"
  local c st
  for c in $CONTAINERS; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null || echo missing)
    case "$st" in
      "running healthy"|"running no-healthcheck") ok "$c $st" ;;
      *) bad "$c $st" ;;
    esac
  done
  local others; others=$(docker ps --format '{{.Names}}' | grep -E 'paperless|immich|archivebox|archivewarrior' || true)
  [ -z "$others" ] && ok "no phase-2 containers running" || bad "running but not in phase 1: $others"

  step "published ports (127.0.0.1 only)"
  local wide; wide=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E 'mediasort|cannoncommander|atuin|hedgedoc|filestash|rackpeek' | grep -E '0\.0\.0\.0|:::' || true)
  [ -z "$wide" ] && ok "all on 127.0.0.1" || bad "published beyond 127.0.0.1: $wide"

  step "Tailscale Services"
  local s name status; status=$(tailscale serve status 2>/dev/null || true)
  for s in $SERVICES; do
    name=${s%%:*}
    echo "$status" | grep -q "svc:$name" && ok "svc:$name served" || bad "svc:$name not served (bash $0 --serve)"
  done

  step "Atuin registration"
  local env_file="$OUT_DIR/apps.env"
  if [ -f "$A/atuin/config/atuin.db" ] && docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kr-ccp-atuin-0101 2>/dev/null | grep -qx 'ATUIN_OPEN_REGISTRATION=true'; then
    bad "still open: re-run this script, paste $env_file, restart the stack"
  else ok "closed (or no account yet)"; fi

  echo; [ "$FAIL" -eq 0 ] && echo "verify: all ok" || { echo "verify: failures above"; exit 1; }
}

case "$MODE" in
  apply|dry) prepare ;;
  serve) serve ;;
  verify) verify ;;
esac
