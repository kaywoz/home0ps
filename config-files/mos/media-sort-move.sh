#!/bin/bash
# media-sort-move.sh: move the media mover (media-sort.py, kaywoz/home0ps#260) off the boot stick into
# <appdata>/home0ps on the disk path, next to apps-stack.sh (kaywoz, 2026-11-19). One-off.
#
# The mover needs the pool and the network anyway, so nothing of it belongs on /boot, and its state file
# was written to the stick every hour. Moved: media-sort.env, .token, .slack, .inprogress (copied as they
# are, then the env's paths are rewritten); media-sort.py is fetched fresh from the repo (new defaults).
# rclone.conf stays where it is: media-mount.sh shares it (its own change).
#
# Run as root on the homenas:
#   bash media-sort-move.sh --dry-run      show what would change
#   bash media-sort-move.sh                copy to the new place (existing targets are kept, never overwritten)
#   bash media-sort-move.sh --verify       check the new place; exit 1 on a failure
#   bash media-sort-move.sh --remove-old   after --verify passes and the cron lines point at the new
#                                          place: delete the old copies on /boot
#
# It takes the mover's own lock (/run/media-sort.lock), so it never runs while the mover does.
#
# Environment (optional): MOS_DOCKER=/var/mergerfs/merger-nvme/disk1/mos-docker,
#   OLD=/boot/config/home0ps, REPO_RAW=https://raw.githubusercontent.com/kaywoz/home0ps/main
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --verify) MODE=verify ;;
  --remove-old) MODE=remove ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

MOS_DOCKER="${MOS_DOCKER:-/var/mergerfs/merger-nvme/disk1/mos-docker}"
case "$MOS_DOCKER" in /mnt/merger*) echo "MOS_DOCKER is the mergerfs mount: use the disk path." >&2; exit 1 ;; esac
H="$MOS_DOCKER/appdata/home0ps"
OLD="${OLD:-/boot/config/home0ps}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kaywoz/home0ps/main}"
FILES="media-sort.env media-sort.token media-sort.slack media-sort.inprogress"

FAIL=0
step() { echo; echo "== $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
run()  { if [ "$MODE" = dry ]; then echo "  + $*"; else "$@"; fi; }

lock() {   # the mover's own lock: never touch its files while it runs
  exec 9>/run/media-sort.lock
  flock -n 9 || { echo "The mover is running right now; try again when it's done." >&2; exit 1; }
}

apply() {
  [ -d "$MOS_DOCKER/appdata" ] || { echo "$MOS_DOCKER/appdata doesn't exist." >&2; exit 1; }
  [ "$MODE" = dry ] || lock
  run install -d -m 700 "$H"

  step "media-sort.py (fresh from the repo)"
  note "fetch $REPO_RAW/config-files/mos/media-sort.py -> $H/media-sort.py"
  if [ "$MODE" != dry ]; then
    curl -fsSL "$REPO_RAW/config-files/mos/media-sort.py" -o "$H/media-sort.py.new"
    python3 -m py_compile "$H/media-sort.py.new" && rm -rf "$H/__pycache__"
    mv "$H/media-sort.py.new" "$H/media-sort.py"; chmod 700 "$H/media-sort.py"
    ok "fetched and compiles"
  fi

  step "settings, token, webhook, state"
  local f
  for f in $FILES; do
    if [ -e "$H/$f" ]; then ok "$f already in $H (kept)"
    elif [ -e "$OLD/$f" ]; then note "copy $OLD/$f"; run cp -p "$OLD/$f" "$H/$f"; run chmod 600 "$H/$f"
    else
      case "$f" in
        media-sort.env) echo "No $OLD/media-sort.env: start from config-files/mos/media-sort.env.example instead." >&2; exit 1 ;;
        *) note "$f: not on $OLD either (fine: optional or created when needed)" ;;
      esac
    fi
  done

  step "paths inside media-sort.env"
  if [ "$MODE" = dry ]; then note "would rewrite $OLD/media-sort.* -> $H/media-sort.* in $H/media-sort.env"
  else
    sed -i "s#$OLD/media-sort\.#$H/media-sort.#g" "$H/media-sort.env"
    grep -q "$OLD/media-sort\." "$H/media-sort.env" && bad "old paths left in $H/media-sort.env" || ok "rewritten"
  fi
  local envf="$H/media-sort.env"; [ -f "$envf" ] || envf="$OLD/media-sort.env"
  local cu; cu=$(sed -n 's/^CLASSIFIER_URL=//p' "$envf" 2>/dev/null || true)
  [ "$cu" = "http://127.0.0.1:8089" ] && ok "CLASSIFIER_URL=$cu" \
    || note "CLASSIFIER_URL is '$cu': set it to http://127.0.0.1:8089 in $H/media-sort.env once the apps stack runs (the apps VM is gone)"

  [ "$MODE" = dry ] && return 0
  cat <<MSG

Next, in the MOS UI's cron jobs, change the four mover lines to:
  0 * * * *   python3 $H/media-sort.py sort
  30 4 * * *  python3 $H/media-sort.py junk
  45 4 * * *  python3 $H/media-sort.py holding
  0 8 * * *   python3 $H/media-sort.py digest
Then:  bash $0 --verify   and, when it passes,   bash $0 --remove-old
MSG
}

verify() {
  local f m
  step "new place: $H"
  [ -f "$H/media-sort.py" ] && python3 -m py_compile "$H/media-sort.py" 2>/dev/null && ok "media-sort.py compiles" || bad "media-sort.py missing or broken"
  rm -rf "$H/__pycache__"
  for f in media-sort.env media-sort.token; do
    if [ -f "$H/$f" ]; then m=$(stat -c '%u %a' "$H/$f"); [ "$m" = "0 600" ] && ok "$f (root, 600)" || bad "$f is '$m', expected '0 600'"
    else bad "$f missing"; fi
  done
  [ -f "$H/media-sort.slack" ] && { m=$(stat -c '%u %a' "$H/media-sort.slack"); [ "$m" = "0 600" ] && ok "media-sort.slack (root, 600)" || bad "media-sort.slack is '$m'"; } || note "media-sort.slack absent (only needed with RUN_DIGEST=1)"
  if [ -f "$H/media-sort.env" ]; then
    grep -q "$OLD/media-sort\." "$H/media-sort.env" && bad "media-sort.env still points at $OLD" || ok "media-sort.env points at $H"
  fi
  step "mover's token = mediasort's token"
  local ms="$MOS_DOCKER/appdata/mediasort/secrets/token"
  if [ -f "$ms" ]; then cmp -s "$ms" "$H/media-sort.token" && ok "match" || bad "differ: copy one over the other (mediasort's: $ms)"
  else note "mediasort's token not there yet (apps-stack.sh creates it from this one)"; fi
  step "old copies on $OLD"
  local left=""; for f in media-sort.py $FILES; do [ -e "$OLD/$f" ] && left="$left $f"; done
  [ -z "$left" ] && ok "none left" || note "still there:$left (bash $0 --remove-old once the cron lines are changed)"
  echo; [ "$FAIL" -eq 0 ] && echo "verify: all ok" || { echo "verify: failures above"; return 1; }
}

remove_old() {
  lock
  verify >/dev/null || { echo "--verify fails: fix that first (bash $0 --verify)." >&2; exit 1; }
  local f
  step "delete the old copies on $OLD"
  for f in media-sort.py $FILES; do
    [ -e "$OLD/$f" ] && { rm -f "$OLD/$f"; ok "deleted $OLD/$f"; } || true
  done
  echo; echo "Check the cron lines in the MOS UI point at $H: the old script is gone now."
}

case "$MODE" in
  apply|dry) apply ;;
  verify) verify || exit 1 ;;
  remove) remove_old ;;
esac
