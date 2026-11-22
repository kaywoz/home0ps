#!/bin/bash
# infra-stack.sh: prepare, serve and verify the homenas infra stack with Arcane
# (docker-compose/homenas/infra/, kaywoz/home0ps#352, #320).
#
# Arcane is the homenas's Docker UI and git-sync deployer; cloudflared runs next to it. The socket proxy and
# Beszel agent stay behind the `monitoring` profile (off). The infra stack itself stays a MOS stack, so MOS
# autostart brings Arcane back after a reboot.
#
# Run as root on the homenas. Files live in <appdata>/home0ps on the disk path, like apps-stack.sh:
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/mos/infra-stack.sh \
#     -o /var/mergerfs/merger-nvme/disk1/mos-docker/appdata/home0ps/infra-stack.sh
#
#   bash $H/infra-stack.sh --dry-run   show what would change
#   bash $H/infra-stack.sh             Arcane's folders and secrets, the stack's .env and compose.yaml to paste
#                                      into the existing MOS stack "infra"
#   bash $H/infra-stack.sh --serve     svc:arcane (after the stack runs and the Tailscale PRs are merged)
#   bash $H/infra-stack.sh --verify    check everything, change nothing; exit 1 on a failure
#
# Re-runnable: existing secrets are kept, never overwritten. Nothing prints a secret.
# File names (CLAUDE.md §8): what you write is $H/infra-stack.conf (optional, no secrets); what the script
# generates goes to $H/infra-stack/: mos.env (the MOS stack's environment) and compose.yaml.
# Optional settings (environment or $H/infra-stack.conf):
#   TZ=<Area/City>   [read from /etc/localtime, else required]
#   MOS_DOCKER=/var/mergerfs/merger-nvme/disk1/mos-docker   Docker's own files: disk path, never /mnt/merger-*
#   REPO_RAW=https://raw.githubusercontent.com/kaywoz/home0ps/main
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Compose CLI: the plugin (`docker compose`) where installed, else the standalone `docker-compose` that
# MOS itself uses (its autostart runs docker-compose); the plugin isn't always there.
dc() { if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --serve) MODE=serve ;;
  --verify) MODE=verify ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

MOS_DOCKER="${MOS_DOCKER:-/var/mergerfs/merger-nvme/disk1/mos-docker}"
case "$MOS_DOCKER" in /mnt/merger*) echo "MOS_DOCKER is the mergerfs mount: use the disk path." >&2; exit 1 ;; esac
H="$MOS_DOCKER/appdata/home0ps"
# shellcheck disable=SC1091
[ ! -e "$H/infra-stack.conf" ] && [ -f "$H/infra-stack.env" ] && mv "$H/infra-stack.env" "$H/infra-stack.conf"   # old name
[ -r "$H/infra-stack.conf" ] && . "$H/infra-stack.conf"
A="$MOS_DOCKER/appdata"
OUT_DIR="$H/infra-stack"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kaywoz/home0ps/main}"
ARC_UID=2202
SEC="$A/arcane/secrets"

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }

dir() {   # dir <path> <uid>: create (700) or fix the owner
  if [ -d "$1" ]; then
    [ "$(stat -c '%u:%g' "$1")" = "$2:$2" ] && return 0
    note "re-own $1 to $2:$2"; run chown "$2:$2" "$1"
  else
    note "create $1 ($2:$2, 700)"; run install -d -m 700 -o "$2" -g "$2" "$1"
  fi
}

check_file() {   # check_file <path> <uid>: exists, owned by uid, 600
  if [ ! -f "$1" ]; then bad "$1 missing"; return; fi
  local m; m=$(stat -c '%u %a' "$1")
  [ "$m" = "$2 600" ] && ok "$1 ($2, 600)" || bad "$1 is '$m', expected '$2 600'"
}

tailnet() {
  tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["MagicDNSSuffix"].removesuffix(".ts.net"))'
}

tz() {
  [ -n "${TZ:-}" ] && { echo "$TZ"; return; }
  readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p'
}

prepare() {
  command -v docker >/dev/null || { echo "docker not found: start Docker from the MOS UI first." >&2; exit 1; }
  [ -d "$A" ] || { echo "$A doesn't exist." >&2; exit 1; }

  step "Arcane folders"
  dir "$A/arcane" "$ARC_UID"; dir "$A/arcane/data" "$ARC_UID"
  dir "$A/arcane/projects" "$ARC_UID"; dir "$SEC" "$ARC_UID"

  step "Arcane encryption key"
  if [ -f "$SEC/encryption_key" ]; then ok "present (kept: changing it makes Arcane's stored secrets unreadable)"
  else
    note "generate $SEC/encryption_key (hex: + 32 random bytes)"
    if [ "$MODE" != dry ]; then
      (umask 077; printf 'hex:%s' "$(openssl rand -hex 32)" > "$SEC/encryption_key")
      chown "$ARC_UID:$ARC_UID" "$SEC/encryption_key"
    fi
  fi

  step "Arcane first admin password"
  if [ -f "$SEC/admin_password" ]; then ok "present (kept; after the first login, change it in Arcane)"
  elif [ "$MODE" = dry ]; then note "would ask for the first admin password and write $SEC/admin_password"
  else
    local pw pw2
    read -rs -p "  Arcane first admin password (12+ characters, upper, lower, digit, symbol): " pw < /dev/tty; echo
    read -rs -p "  again: " pw2 < /dev/tty; echo
    [ "$pw" = "$pw2" ] || { echo "Passwords differ." >&2; exit 1; }
    # Arcane's own policy: without it, Arcane creates no admin at all and every login fails
    # ("password must be at least 12 characters and include an uppercase letter, a lowercase letter,
    # a number, and a symbol", backend/internal/user/service.go CreateDefaultAdmin)
    [ "${#pw}" -ge 12 ] || { echo "Shorter than 12 characters." >&2; exit 1; }
    case "$pw" in *[[:upper:]]*) ;; *) echo "No uppercase letter (Arcane's policy)." >&2; exit 1 ;; esac
    case "$pw" in *[[:lower:]]*) ;; *) echo "No lowercase letter (Arcane's policy)." >&2; exit 1 ;; esac
    case "$pw" in *[[:digit:]]*) ;; *) echo "No number (Arcane's policy)." >&2; exit 1 ;; esac
    case "$pw" in *[![:alnum:]]*) ;; *) echo "No symbol (Arcane's policy)." >&2; exit 1 ;; esac
    (umask 077; printf '%s' "$pw" > "$SEC/admin_password"); unset pw pw2
    chown "$ARC_UID:$ARC_UID" "$SEC/admin_password"; ok "written (600, $ARC_UID)"
  fi

  step "the stack's .env and compose.yaml (to paste into the MOS stack \"infra\")"
  local tn ip zone
  tn=$(tailnet); ip=$(tailscale ip -4 | head -1); zone=$(tz)
  [ -n "$tn" ] || { echo "Couldn't read the tailnet name (tailscale status)." >&2; exit 1; }
  [ -n "$zone" ] || { echo "Couldn't read the time zone: set TZ=<Area/City> in $H/infra-stack.conf." >&2; exit 1; }
  run install -d -m 700 "$OUT_DIR"
  if [ "$MODE" = dry ]; then
    note "would fetch compose.yaml from $REPO_RAW and render $OUT_DIR/mos.env (TZ=$zone)"; return 0
  fi
  curl -fsSL "$REPO_RAW/docker-compose/homenas/infra/compose.yaml" -o "$OUT_DIR/compose.yaml"
  rm -f "$OUT_DIR/infra.env"   # old name of mos.env
  (umask 077; cat > "$OUT_DIR/mos.env" <<EOF
# GENERATED by infra-stack.sh $(date +%F). The MOS stack "infra" environment. Don't edit: re-run the script.
APPDATA=$A
TAILNET=$tn
TZ=$zone
BESZEL_LISTEN=$ip:45876
EOF
)
  ( cd "$OUT_DIR" && dc -f compose.yaml --env-file mos.env config --quiet ) \
    && ok "rendered and validated: $OUT_DIR/compose.yaml, $OUT_DIR/mos.env" \
    || bad "docker compose config failed on the rendered files"
  local services; services=$(cd "$OUT_DIR" && dc -f compose.yaml --env-file mos.env config --services | sort | tr '\n' ' ')
  [ "$services" = "arcane cloudflared " ] && ok "services: $services(monitoring profile off)" || bad "unexpected services: $services"

  cat <<MSG

Next:
  1. MOS UI -> Docker -> Stacks -> "infra" -> edit: replace the compose with $OUT_DIR/compose.yaml and the
     environment with $OUT_DIR/mos.env. Save, then restart the stack. Autostart stays on.
  2. Once the Tailscale PRs for svc:arcane are merged: bash $0 --serve
  3. In Arcane (https://arcane.$tn.ts.net): sign in with the admin password you just set, change it, add a
     passkey. Add this repo as a Git repository (public, no credential) and one pull-only sync per stack
     (docker-compose/homenas/<stack>/compose.yaml, branch main), with each stack's .env values in its project.
  4. bash $0 --verify
MSG
}

serve() {
  step "svc:arcane -> 127.0.0.1:3552"
  tailscale serve --service=svc:arcane --https=443 127.0.0.1:3552   # same form as the other Services in this repo
  echo; tailscale serve status
}

verify() {
  step "secret files"
  check_file "$SEC/encryption_key" "$ARC_UID"
  check_file "$SEC/admin_password" "$ARC_UID"
  step "containers"
  local c st
  for c in kr-ccp-arcane-0101 kr-ccp-cloudflared-0101; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null || echo missing)
    case "$st" in "running healthy"|"running no-healthcheck") ok "$c $st" ;; *) bad "$c $st" ;; esac
  done
  step "Arcane's port and env"
  local p; p=$(docker port kr-ccp-arcane-0101 3552/tcp 2>/dev/null || true)
  [ "$p" = "127.0.0.1:3552" ] && ok "published on 127.0.0.1:3552 only" || bad "published as '$p'"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kr-ccp-arcane-0101 2>/dev/null \
    | grep -qE '^ARCANE_(ENCRYPTION_KEY|DEFAULT_ADMIN_PASSWORD)=' && bad "a secret is set as an env value" || ok "secrets only as files"
  step "Tailscale Service"
  tailscale serve status 2>/dev/null | grep -q 'svc:arcane' && ok "svc:arcane served" || bad "svc:arcane not served (bash $0 --serve)"
  echo; [ "$FAIL" -eq 0 ] && echo "verify: all ok" || { echo "verify: failures above"; return 1; }
}

case "$MODE" in
  apply|dry) prepare ;;
  serve) serve ;;
  verify) verify || exit 1 ;;
esac
