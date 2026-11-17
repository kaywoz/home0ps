#!/bin/bash
# bootstrap-docker-userns.sh: set up persistent Docker userns-remap on a MOS host (kaywoz/home0ps#310).
#
# What it sets up (MOS 0.6.2; /etc is RAM and rebuilt at boot, /boot persists and is noexec):
#   /boot/config/home0ps/docker-userns.sh    the hook: writes /etc/subuid + /etc/subgid (pinned range),
#                                            the remap user and /etc/docker/daemon.json; checks Docker
#   /boot/config/home0ps/docker-userns.env   settings (600): range, reviewed init-script checksum, HC_URL
#   /boot/optional/scripts/pre-start.sh      MOS runs it from mos-start BEFORE Docker, LXC and cron;
#                                            it calls the hook, so Docker's first start is remapped
#   MOS UI cron (by hand, printed at the end) the hook every minute as a guard
#
# Effect: container uid N runs as host uid REMAP_BASE+N. Docker keeps a separate data root
# (/var/lib/docker/<base>.<base>): existing containers, images and volumes are not visible after the
# switch, and appdata must be owned by REMAP_BASE + the container uid.
#
# Usage (root, on the MOS host):
#   bash bootstrap-docker-userns.sh            install/update; remap applies at the next Docker start
#   bash bootstrap-docker-userns.sh --now      install/update, then apply now (restarts Docker once)
#   bash bootstrap-docker-userns.sh --reseal   record the current /etc/init.d/docker checksum
#                                              (after reviewing it, e.g. following a MOS update)
#   bash bootstrap-docker-userns.sh --uninstall
#   FORCE=1 ...                                proceed although the unremapped Docker store has containers
#
# Sources: the hook is taken from this script's folder, else downloaded from SRC_URL.
# Settings (environment or existing env file): REMAP_USER=dockremap REMAP_BASE=165536 REMAP_RANGE=65536
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SRC_URL="${SRC_URL:-https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/mos}"
DIR=/boot/config/home0ps
HOOK="$DIR/docker-userns.sh"; ENV_FILE="$DIR/docker-userns.env"
PRE=/boot/optional/scripts/pre-start.sh
INIT=/etc/init.d/docker; DOCKER_JSON=/boot/config/docker.json
HOOK_LINE="bash $HOOK || true"
MARK="# home0ps: userns-remap config before Docker starts"
CRON_LINE="* * * * * bash $HOOK"

say()  { echo "== $*"; }
warn() { echo "WARN $*" >&2; }
die()  { echo "FAIL $*" >&2; exit 1; }

MODE=install
case "${1:-}" in
  "") ;; --now) MODE=now ;; --reseal) MODE=reseal ;; --uninstall) MODE=uninstall ;;
  *) die "unknown option: $1" ;;
esac

[ "$(id -u)" = 0 ] || die "run as root"
[ -x /usr/local/bin/mos-start ] && [ -f "$DOCKER_JSON" ] && [ -f "$INIT" ] || die "not a MOS host (mos-start, $DOCKER_JSON, $INIT)"
grep -q 'optional/scripts/pre-start.sh' /usr/local/bin/mos-start || die "mos-start no longer runs pre-start.sh: review before installing"
command -v jq >/dev/null || die "jq missing"

init_sha() { sha256sum "$INIT" | cut -d' ' -f1; }
set_env() {   # set_env KEY VALUE: replace or add, keep everything else (HC_URL stays)
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  sed -i "/^$1=/d" "$ENV_FILE"; echo "$1=$2" >> "$ENV_FILE"
}

if [ "$MODE" = reseal ]; then
  [ -f "$ENV_FILE" ] || die "$ENV_FILE missing: install first"
  set_env INIT_SHA "$(init_sha)"; say "INIT_SHA recorded: $(init_sha)"; exit 0
fi

if [ "$MODE" = uninstall ]; then
  if [ -f "$PRE" ]; then
    grep -vF "$MARK" "$PRE" | grep -vxF "$HOOK_LINE" > "$PRE.new" || true
    mv "$PRE.new" "$PRE"; chmod 600 "$PRE"
    # only a shebang/comments/blank lines left -> it was ours alone
    grep -qvE '^#|^[[:space:]]*$' "$PRE" && say "hook call removed from $PRE" || { rm -f "$PRE"; say "removed $PRE"; }
  fi
  rm -f "$HOOK" "$ENV_FILE"; rm -rf /run/docker-userns
  grep -q '"userns-remap"' /etc/docker/daemon.json 2>/dev/null && rm -f /etc/docker/daemon.json
  say "removed hook, env file and daemon.json"
  say "by hand: delete the cron line in the MOS UI ($CRON_LINE), then restart Docker from the MOS UI"
  say "remapped store stays at /var/lib/docker/<base>.<base>; appdata keeps its remapped owners"
  exit 0
fi

# --- settings: existing env file wins over defaults, environment wins over both ---
E_USER="${REMAP_USER:-}"; E_BASE="${REMAP_BASE:-}"; E_RANGE="${REMAP_RANGE:-}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
REMAP_USER="${E_USER:-${REMAP_USER:-dockremap}}"
REMAP_BASE="${E_BASE:-${REMAP_BASE:-165536}}"
REMAP_RANGE="${E_RANGE:-${REMAP_RANGE:-65536}}"

# --- preflight ---
opts=$(jq -r '.docker_options // ""' "$DOCKER_JSON")
case "$opts" in *userns-remap*) die "Docker start parameters already contain --userns-remap: remove it (dockerd refuses the flag and daemon.json together)";; esac
if [ -s /etc/docker/daemon.json ] && ! grep -q "\"userns-remap\": \"$REMAP_USER\"" /etc/docker/daemon.json; then
  die "/etc/docker/daemon.json exists and wasn't written by the hook: merge by hand"
fi
for f in /etc/subuid /etc/subgid; do
  [ -f "$f" ] || continue
  awk -F: -v u="$REMAP_USER" -v b="$REMAP_BASE" -v r="$REMAP_RANGE" \
    '$1 != u && NF == 3 && $2 < b + r && $2 + $3 > b {bad=1} END {exit !bad}' "$f" \
    && die "$f has a range overlapping $REMAP_BASE:$REMAP_RANGE: choose another REMAP_BASE"
done
if docker info >/dev/null 2>&1; then
  root=$(docker info --format '{{.DockerRootDir}}')
  case "$root" in
    */"$REMAP_BASE.$REMAP_BASE") say "Docker already runs remapped ($root)" ;;
    *) n=$(docker ps -aq | wc -l)
       if [ "$n" -gt 0 ]; then
         [ "${FORCE:-}" = 1 ] || die "$n container(s) in the unremapped store ($root): they won't be visible after remap. Recreate them afterwards, re-own their appdata to $REMAP_BASE+uid, then rerun with FORCE=1"
         warn "$n container(s) in $root stay behind (FORCE=1)"
       fi ;;
  esac
else
  warn "Docker isn't running: can't check for containers in the unremapped store"
fi

# --- install ---
mkdir -p "$DIR" /boot/optional/scripts
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$here/docker-userns.sh" ] && [ "$here" != "$DIR" ]; then
  cp "$here/docker-userns.sh" "$HOOK.new"
else
  curl -fsSL -m 30 "$SRC_URL/docker-userns.sh" -o "$HOOK.new" || die "download failed: $SRC_URL/docker-userns.sh"
fi
bash -n "$HOOK.new" || { rm -f "$HOOK.new"; die "hook doesn't parse"; }
mv "$HOOK.new" "$HOOK"; chmod 600 "$HOOK"; say "hook: $HOOK"

set_env REMAP_USER "$REMAP_USER"; set_env REMAP_BASE "$REMAP_BASE"; set_env REMAP_RANGE "$REMAP_RANGE"
grep -q '^INIT_SHA=.' "$ENV_FILE" || set_env INIT_SHA "$(init_sha)"
grep -q 'HC_URL=' "$ENV_FILE" || echo "#HC_URL=" >> "$ENV_FILE"
say "settings: $ENV_FILE ($REMAP_USER $REMAP_BASE:$REMAP_RANGE; INIT_SHA = current $INIT, review it)"

if [ ! -f "$PRE" ]; then
  printf '#!/bin/bash\n%s (kaywoz/home0ps#310). Must never fail the boot.\n%s\n' "$MARK" "$HOOK_LINE" > "$PRE"
  say "pre-start: created $PRE"
elif grep -qxF "$HOOK_LINE" "$PRE"; then
  say "pre-start: already calls the hook"
else
  printf '\n%s (kaywoz/home0ps#310). Must never fail the boot.\n%s\n' "$MARK" "$HOOK_LINE" >> "$PRE"
  say "pre-start: hook call appended to the existing $PRE"
fi
chmod 600 "$PRE"

# writes the config; restarts Docker only if it runs unremapped
if [ "$MODE" = now ]; then
  bash "$HOOK" || warn "hook reported a problem: see /var/log/docker-userns.log"
else
  say "remap applies at the next Docker start (reboot), or rerun with --now"
fi
bash "$HOOK" --check || true

cat <<EOF

== by hand, in the MOS UI:
   cron jobs: add   $CRON_LINE
   containers/stacks: autostart on for everything that should come back after a reboot
   (MOS's Docker stop runs 'docker stop', so restart: unless-stopped alone doesn't bring them back)
   Docker start parameters: leave without --userns-remap
== appdata: owner = $REMAP_BASE + the container's uid (root in the container = $REMAP_BASE)
== after a MOS update: if the hook alerts "init script changed", review $INIT, then --reseal
EOF
