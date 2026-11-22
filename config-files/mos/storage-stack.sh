#!/bin/bash
# storage-stack.sh: prepare, serve and verify the homenas storage stack
# (docker-compose/homenas/storage/: Kopia, RustFS, Time Machine; kaywoz/home0ps#320).
#
# The stack runs as the Arcane project "storage" (pull-only git sync of compose.yaml from main). The Scrutiny
# collector stays behind its `cron` profile (its hub on the monitoring host isn't running).
#
# Run as root on the homenas. Files live in <appdata>/home0ps on the disk path, like apps-stack.sh:
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/mos/storage-stack.sh \
#     -o /var/mergerfs/merger-nvme/disk1/mos-docker/appdata/home0ps/storage-stack.sh
#
#   bash $H/storage-stack.sh --dry-run   show what would change
#   bash $H/storage-stack.sh             folders, secrets, the stack's .env values for its Arcane project
#   bash $H/storage-stack.sh --serve     svc:kopia, svc:rustfs, svc:s3 (after the stack runs)
#   bash $H/storage-stack.sh --verify    check everything, change nothing; exit 1 on a failure
#
# Re-runnable: existing secrets are kept, never overwritten. Nothing prints a secret.
# File names (CLAUDE.md §8): what you write is $H/storage-stack.conf; what the script generates goes to
# $H/storage-stack/: arcane.env (the Arcane project's environment) and compose.yaml (for reference).
# Settings ($H/storage-stack.conf, no secrets; template: config-files/mos/storage-stack.conf.example):
#   VLAN11_SUBNET  VLAN11_GATEWAY  VLAN11_RANGE  TIMEMACHINE_IP   Time Machine's macvlan on VLAN 11 [required]
#   VLAN11_PARENT=eth0.11
#   BACKUPS=/mnt/merger-nvme/2.backup/kopia  TIMEMACHINE=/mnt/merger-nvme/2.backup/timemachine
#   S3DATA=/mnt/merger-nvme/2.backup/s3      pool folders (service data goes through mergerfs)
#   MOS_DOCKER=/var/mergerfs/merger-nvme/disk1/mos-docker   Docker's own files: disk path, never /mnt/merger-*
#   REPO_RAW=https://raw.githubusercontent.com/kaywoz/home0ps/main
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
trap 'echo "storage-stack.sh: failed at line $LINENO" >&2' ERR
# Compose CLI: the plugin (`docker compose`) where installed, else the standalone `docker-compose` MOS uses.
dc() { if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --serve) MODE=serve ;;
  --verify) MODE=verify ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

MOS_DOCKER="${MOS_DOCKER:-/var/mergerfs/merger-nvme/disk1/mos-docker}"
case "$MOS_DOCKER" in /mnt/merger*) echo "MOS_DOCKER is the mergerfs mount: use the disk path." >&2; exit 1 ;; esac
H="$MOS_DOCKER/appdata/home0ps"
CONF="$H/storage-stack.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
A="$MOS_DOCKER/appdata"
OUT_DIR="$H/storage-stack"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kaywoz/home0ps/main}"
VLAN11_PARENT="${VLAN11_PARENT:-eth0.11}"
BACKUPS="${BACKUPS:-/mnt/merger-nvme/2.backup/kopia}"
TIMEMACHINE="${TIMEMACHINE:-/mnt/merger-nvme/2.backup/timemachine}"
S3DATA="${S3DATA:-/mnt/merger-nvme/2.backup/s3}"
VLAN11_SUBNET="${VLAN11_SUBNET:-}"; VLAN11_GATEWAY="${VLAN11_GATEWAY:-}"
VLAN11_RANGE="${VLAN11_RANGE:-}"; TIMEMACHINE_IP="${TIMEMACHINE_IP:-}"

# Services: name target (the host's tailscaled serves them; tag:storage auto-approves)
SERVICES="kopia:https+insecure://127.0.0.1:51515 rustfs:http://127.0.0.1:9001 s3:http://127.0.0.1:9000"
CONTAINERS="kr-ccp-kopia-0101 kr-ccp-rustfs-0101 kr-ccp-timemachine-0101"
KOPIA_UID=2301; RUSTFS_UID=2302; TM_UID=2303

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }

need_vlan() {
  local v
  for v in VLAN11_SUBNET VLAN11_GATEWAY VLAN11_RANGE TIMEMACHINE_IP; do
    [ -n "${!v}" ] || { echo "$v is not set (in $CONF)." >&2; exit 1; }
  done
}

# dir <path> <uid> <gid> [mode]: create, or fix the owner (never recursive)
dir() {
  if [ -d "$1" ]; then
    [ "$(stat -c '%u:%g' "$1")" = "$2:$3" ] && return 0
    note "re-own $1 to $2:$3"; run chown "$2:$3" "$1"
  else
    note "create $1 ($2:$3, ${4:-700})"; run install -d -m "${4:-700}" -o "$2" -g "$3" "$1"
  fi
}

# check_file <path> <uid>: exists, owned by uid, mode 600
check_file() {
  if [ ! -f "$1" ]; then bad "$1 missing"; return; fi
  local m; m=$(stat -c '%u %a' "$1")
  [ "$m" = "$2 600" ] && ok "$1 ($2, 600)" || bad "$1 is '$m', expected '$2 600'"
}

tailnet() {
  tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["MagicDNSSuffix"].removesuffix(".ts.net"))'
}

# ---- prepare (default and --dry-run) ------------------------------------------------------
prepare() {
  need_vlan
  command -v docker >/dev/null || { echo "docker not found: start Docker from the MOS UI first." >&2; exit 1; }
  command -v openssl >/dev/null || { echo "openssl not found." >&2; exit 1; }
  [ -d "$A" ] || { echo "APPDATA $A doesn't exist." >&2; exit 1; }

  step "folders"
  dir "$A/kopia" $KOPIA_UID $KOPIA_UID;         dir "$A/kopia/config" $KOPIA_UID $KOPIA_UID
  dir "$A/kopia/cache" $KOPIA_UID $KOPIA_UID;   dir "$A/kopia/logs" $KOPIA_UID $KOPIA_UID
  dir "$A/rustfs" $RUSTFS_UID $RUSTFS_UID;      dir "$A/rustfs/secrets" $RUSTFS_UID $RUSTFS_UID
  dir "$A/rustfs/logs" $RUSTFS_UID $RUSTFS_UID
  dir "$A/timemachine" 0 0
  # pool folders: Kopia's repository, the Time Machine share, the S3 buckets
  dir "$BACKUPS" $KOPIA_UID $KOPIA_UID 755
  dir "$TIMEMACHINE" $TM_UID $TM_UID 755
  dir "$S3DATA" $RUSTFS_UID $RUSTFS_UID 755

  step "Kopia: TLS certificate and UI login"
  local kc="$A/kopia/config"
  if [ -f "$kc/tls.key" ] && [ -f "$kc/tls.crt" ]; then ok "tls.key, tls.crt present (kept)"
  else
    note "generate a self-signed certificate (10 years; the Service connects with https+insecure)"
    if [ "$MODE" != dry ]; then
      (umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj /CN=kopia -keyout "$kc/tls.key" -out "$kc/tls.crt" 2>/dev/null)
      chown $KOPIA_UID:$KOPIA_UID "$kc/tls.key" "$kc/tls.crt"
    fi
  fi
  if [ -f "$kc/htpasswd" ]; then ok "htpasswd present (kept)"
  elif [ "$MODE" = dry ]; then note "would ask for the Kopia UI password (user kopia)"
  else
    # The web UI only admits the account named `kopia` (maintainer, kopia/kopia#880); any other htpasswd
    # user is a repository user and gets "UI Access denied".
    local pw pw2
    read -rs -p "  Kopia UI password (user kopia): " pw < /dev/tty; echo
    read -rs -p "  again: " pw2 < /dev/tty; echo
    [ -n "$pw" ] && [ "$pw" = "$pw2" ] || { echo "Empty or not matching." >&2; exit 1; }
    (umask 077; printf 'kopia:%s\n' "$(openssl passwd -apr1 "$pw")" > "$kc/htpasswd"); unset pw pw2
    chown $KOPIA_UID:$KOPIA_UID "$kc/htpasswd"; ok "htpasswd written (600, $KOPIA_UID)"
  fi

  step "RustFS keys"
  local rs="$A/rustfs/secrets"
  if [ -f "$rs/access_key" ] && [ -f "$rs/secret_key" ]; then ok "access_key, secret_key present (kept)"
  else
    note "generate access_key and secret_key (read them from $rs into 1Password)"
    if [ "$MODE" != dry ]; then
      [ -f "$rs/access_key" ] || (umask 077; openssl rand -hex 10 | tr -d '\n' > "$rs/access_key")
      [ -f "$rs/secret_key" ] || (umask 077; openssl rand -base64 30 | tr -d '\n' > "$rs/secret_key")
      chown $RUSTFS_UID:$RUSTFS_UID "$rs/access_key" "$rs/secret_key"
    fi
  fi

  step "Time Machine share password"
  if [ -f "$A/timemachine/password" ]; then ok "present (kept)"
  elif [ "$MODE" = dry ]; then note "would ask for the Time Machine share password"
  else
    local pw pw2
    read -rs -p "  Time Machine share password (user 'timemachine'): " pw < /dev/tty; echo
    read -rs -p "  again: " pw2 < /dev/tty; echo
    [ -n "$pw" ] && [ "$pw" = "$pw2" ] || { echo "Empty or not matching." >&2; exit 1; }
    (umask 077; printf '%s' "$pw" > "$A/timemachine/password"); unset pw pw2
    ok "written (600, root: the image's entrypoint reads it as root)"
  fi

  step "the stack's .env values for Arcane (and compose.yaml, for reference)"
  local tn; tn=$(tailnet)
  [ -n "$tn" ] || { echo "Couldn't read the tailnet name (tailscale status)." >&2; exit 1; }
  if [ "$MODE" != dry ]; then
    install -d -m 700 "$OUT_DIR"
    local t; t=$(mktemp)
    curl -fsSL "$REPO_RAW/docker-compose/homenas/storage/compose.yaml" -o "$t" && [ -s "$t" ] \
      && install -m 600 "$t" "$OUT_DIR/compose.yaml"; rm -f "$t"
    # No secrets in this file.
    (umask 077; cat > "$OUT_DIR/arcane.env" <<EOF
# GENERATED by storage-stack.sh $(date +%F). The Arcane project "storage" environment. Don't edit: re-run the script.
APPDATA=$A
BACKUPS=$BACKUPS
TIMEMACHINE=$TIMEMACHINE
S3DATA=$S3DATA
VLAN11_PARENT=$VLAN11_PARENT
VLAN11_SUBNET=$VLAN11_SUBNET
VLAN11_GATEWAY=$VLAN11_GATEWAY
VLAN11_RANGE=$VLAN11_RANGE
TIMEMACHINE_IP=$TIMEMACHINE_IP
RUSTFS_CONSOLE_ORIGIN=https://rustfs.$tn.ts.net
# the Scrutiny collector (profile cron) stays off until the monitoring host's hub is back
SCRUTINY_API=unused
EOF
)
    ( cd "$OUT_DIR" && dc -f compose.yaml --env-file arcane.env config --quiet ) \
      && ok "rendered and validated: $OUT_DIR/compose.yaml, $OUT_DIR/arcane.env" \
      || bad "compose config failed on the rendered files"
    local services; services=$(cd "$OUT_DIR" && dc -f compose.yaml --env-file arcane.env config --services | sort | tr '\n' ' ')
    [ "$services" = "kopia rustfs timemachine " ] \
      && ok "services: $services(Scrutiny collector off)" || bad "unexpected services: $services"
  else
    note "would fetch compose.yaml from $REPO_RAW and render $OUT_DIR/arcane.env"
  fi

  [ "$MODE" = dry ] && return 0
  cat <<MSG

Next:
  1. Arcane (https://arcane.$tn.ts.net): project "storage", pull-only git sync, branch main,
     file docker-compose/homenas/storage/compose.yaml; environment = $OUT_DIR/arcane.env. Deploy.
  2. Kopia's repository, once (interactive; save the repository password in 1Password first):
       docker exec -it kr-ccp-kopia-0101 kopia repository create filesystem --path=/repository
       docker restart kr-ccp-kopia-0101
  3. bash $0 --serve
  4. Macs on VLAN 11: Time Machine settings -> Add Backup Disk -> TimeMachine on "timemachine",
     user timemachine; turn on backup encryption.
  5. bash $0 --verify
MSG
}

# ---- --serve ------------------------------------------------------------------------------
serve() {
  local s name target
  for s in $SERVICES; do
    name=${s%%:*}; target=${s#*:}
    step "svc:$name -> $target"
    tailscale serve --service="svc:$name" --https=443 "$target"
  done
  echo; tailscale serve status
}

# ---- --verify -----------------------------------------------------------------------------
verify() {
  need_vlan
  step "secret and config files"
  check_file "$A/kopia/config/tls.key" $KOPIA_UID
  check_file "$A/kopia/config/htpasswd" $KOPIA_UID
  [ "$(cut -d: -f1 "$A/kopia/config/htpasswd" 2>/dev/null | head -1)" = kopia ] && ok "Kopia UI user is kopia" \
    || bad "Kopia's htpasswd user isn't 'kopia': the UI denies any other (kopia/kopia#880)"
  check_file "$A/rustfs/secrets/access_key" $RUSTFS_UID
  check_file "$A/rustfs/secrets/secret_key" $RUSTFS_UID
  check_file "$A/timemachine/password" 0

  step "containers"
  local c st
  for c in $CONTAINERS; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null || echo missing)
    case "$st" in "running healthy"|"running no-healthcheck") ok "$c $st" ;; *) bad "$c $st" ;; esac
  done

  step "published ports (127.0.0.1 only)"
  local wide; wide=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E 'kopia|rustfs' | grep -E '0\.0\.0\.0|:::' || true)
  [ -z "$wide" ] && ok "all on 127.0.0.1" || bad "published beyond 127.0.0.1: $wide"

  step "Kopia repository"
  if [ -f "$A/kopia/config/repository.config" ] \
     && docker exec kr-ccp-kopia-0101 kopia repository status >/dev/null 2>&1; then ok "connected"
  else bad "not connected (create it once: see the default mode's next steps)"; fi

  step "Time Machine"
  local tm; tm=$(docker inspect -f '{{.Config.Hostname}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kr-ccp-timemachine-0101 2>/dev/null || true)
  [ "$tm" = "timemachine $TIMEMACHINE_IP" ] && ok "advertised as timemachine on $TIMEMACHINE_IP" || bad "hostname/address is '$tm', expected 'timemachine $TIMEMACHINE_IP'"
  docker exec kr-ccp-timemachine-0101 pgrep avahi-daemon >/dev/null 2>&1 && ok "avahi running (discovery)" || bad "avahi not running: Macs won't discover the share"
  [ "$(stat -c %u "$TIMEMACHINE")" = $TM_UID ] && ok "$TIMEMACHINE owned $TM_UID" || bad "$TIMEMACHINE not owned $TM_UID"
  local rootb; rootb=$(find "$TIMEMACHINE" -mindepth 1 -maxdepth 1 \( -name '*.sparsebundle' -o -name '*.backupbundle' \) ! -uid $TM_UID -printf '%f\n' 2>/dev/null || true)
  [ -z "$rootb" ] && ok "every backup bundle owned $TM_UID" || bad "bundles the share can't write (chown -R $TM_UID:$TM_UID): $rootb"

  step "Tailscale Services"
  local s name status; status=$(tailscale serve status 2>/dev/null || true)
  for s in $SERVICES; do
    name=${s%%:*}
    echo "$status" | grep "svc:$name" >/dev/null && ok "svc:$name served" || bad "svc:$name not served (bash $0 --serve)"
  done

  echo; [ "$FAIL" -eq 0 ] && echo "verify: all ok" || { echo "verify: failures above"; exit 1; }
}

case "$MODE" in
  apply|dry) prepare ;;
  serve) serve ;;
  verify) verify ;;
esac
