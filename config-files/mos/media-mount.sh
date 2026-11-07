#!/bin/bash
# media-mount.sh — read-only rclone mount of the media library on the MOS host, then start the
# LXCs that bind it (kaywoz/home0ps#197, #174). Idempotent: run it at boot and as a watchdog.
#
# Cron (as root on MOS):
#   @reboot      /boot/config/home0ps/media-mount.sh
#   */5 * * * *  /boot/config/home0ps/media-mount.sh     # watchdog: remounts if the mount died
#
#   media-mount.sh            mount (if needed), then start/restart the LXCs (if needed)
#   media-mount.sh --check    report only, change nothing; exit 1 if anything is wrong
#   media-mount.sh --umount   stop the LXCs that use it, then unmount
#
# Settings come from a host-local env file (NOT in git: remote names and paths stay on the host):
#   /boot/config/home0ps/media-mount.env   (override with MEDIA_MOUNT_ENV=<file>)
#     RCLONE_CONFIG=/boot/config/...      rclone.conf with the crypt remote (persistent, 600)
#     REMOTE=<crypt-remote>:<path>        what to mount
#     MNT=/mnt/media                      mount point on the host (created if missing)
#     CACHE_DIR=/mnt/<pool>/...           VFS cache on the pool — never on MOS's RAM rootfs
#     CACHE_MAX_SIZE=100G  CACHE_MAX_AGE=168h  READ_AHEAD=256M  DIR_CACHE_TIME=15m
#     LOG_FILE=/mnt/<pool>/.../media-mount.log
#     LXCS="kr-cxp-media-0101"            LXCs with a bind entry for $MNT, started after the mount.
#                                         Set their autostart off: if one starts before the
#                                         mount, its bind shows the empty directory underneath.
#     RCLONE_BIN=rclone
#
# rclone flags (rclone docs, commands/rclone_mount): --read-only; --allow-other so the LXC's
# remapped uids can read (FUSE only checks user_allow_other for non-root mounters);
# --umask 0022 → files 0644, dirs 0755, readable as "others" through the uid mapping;
# --daemon waits up to --daemon-wait for a ready mount.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE="${MEDIA_MOUNT_ENV:-/boot/config/home0ps/media-mount.env}"
MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  --umount) MODE=umount ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

log() { echo "$(date '+%F %T') media-mount: $*"; command -v logger >/dev/null 2>&1 && logger -t media-mount "$*" || true; }
die() { log "ABORT: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -r "$ENV_FILE" ] || die "settings file $ENV_FILE missing (see --help)"
# shellcheck disable=SC1090
. "$ENV_FILE"
RCLONE_BIN="${RCLONE_BIN:-rclone}"; MNT="${MNT:-/mnt/media}"
CACHE_MAX_SIZE="${CACHE_MAX_SIZE:-100G}"; CACHE_MAX_AGE="${CACHE_MAX_AGE:-168h}"
READ_AHEAD="${READ_AHEAD:-256M}"; DIR_CACHE_TIME="${DIR_CACHE_TIME:-15m}"; LXCS="${LXCS:-}"
for v in RCLONE_CONFIG REMOTE CACHE_DIR LOG_FILE; do [ -n "${!v:-}" ] || die "$v not set in $ENV_FILE"; done
[ -r "$RCLONE_CONFIG" ] || die "rclone config $RCLONE_CONFIG not readable"
command -v "$RCLONE_BIN" >/dev/null || die "$RCLONE_BIN not found"

# one run at a time (the watchdog can overlap a slow boot mount)
exec 9>/run/media-mount.lock
command -v flock >/dev/null 2>&1 && { flock -n 9 || { log "another run is active, skipping"; exit 0; }; }

is_mounted() { grep " ${MNT} fuse.rclone " /proc/mounts >/dev/null; }
is_healthy() { is_mounted && timeout 20 ls "$MNT" >/dev/null 2>&1; }
fuse_umount() { fusermount3 -uz "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT"; }
lxc_running() { lxc-info -n "$1" -s 2>/dev/null | grep RUNNING >/dev/null; }
# the LXC sees the media when its bind target is non-empty
lxc_sees_media() { [ -n "$(lxc-attach -n "$1" -- ls -A /mnt/media 2>/dev/null | head -1)" ]; }

if [ "$MODE" = check ]; then
  rc=0
  is_healthy && echo "OK   $MNT mounted and readable" || { echo "FAIL $MNT not mounted or not readable"; rc=1; }
  grep " ${MNT} fuse.rclone ro," /proc/mounts >/dev/null && echo "OK   mounted read-only" || { echo "FAIL not mounted read-only"; rc=1; }
  for c in $LXCS; do
    if ! lxc_running "$c"; then echo "FAIL LXC $c not running"; rc=1
    elif lxc_sees_media "$c"; then echo "OK   LXC $c sees the media"
    else echo "FAIL LXC $c runs but /mnt/media is empty (started before the mount?)"; rc=1; fi
  done
  exit "$rc"
fi

if [ "$MODE" = umount ]; then
  for c in $LXCS; do lxc_running "$c" && { log "stopping LXC $c"; lxc-stop -n "$c"; }; done
  is_mounted && { log "unmounting $MNT"; fuse_umount; }
  exit 0
fi

# ---- mount ---------------------------------------------------------------------
MOUNTED_NOW=0
if ! is_healthy; then
  if is_mounted; then log "$MNT is mounted but not readable: lazy unmount"; fuse_umount || true; fi
  mkdir -p "$MNT" "$CACHE_DIR" "$(dirname "$LOG_FILE")"
  [ -z "$(ls -A "$MNT" 2>/dev/null)" ] || die "$MNT is not empty — refusing to mount over files"
  # wait for the network / remote (boot): up to ~5 minutes
  for i in $(seq 30); do
    timeout 30 "$RCLONE_BIN" --config "$RCLONE_CONFIG" lsf --max-depth 1 "$REMOTE" >/dev/null 2>&1 && break
    [ "$i" = 30 ] && die "remote not reachable after 30 tries"
    sleep 10
  done
  log "mounting (read-only) on $MNT"
  "$RCLONE_BIN" mount "$REMOTE" "$MNT" \
    --config "$RCLONE_CONFIG" \
    --read-only --allow-other --uid 0 --gid 0 --umask 0022 \
    --vfs-cache-mode full --cache-dir "$CACHE_DIR" \
    --vfs-cache-max-size "$CACHE_MAX_SIZE" --vfs-cache-max-age "$CACHE_MAX_AGE" \
    --vfs-read-ahead "$READ_AHEAD" --dir-cache-time "$DIR_CACHE_TIME" \
    --log-file "$LOG_FILE" --log-level NOTICE \
    --daemon --daemon-wait 60s
  is_healthy || die "mount did not come up — see $LOG_FILE"
  log "mounted"; MOUNTED_NOW=1
fi

# ---- LXCs: start after a (re)mount; restart one that started before it -----------
# A stopped LXC is only started when this run mounted: the watchdog leaves a stopped LXC alone.
for c in $LXCS; do
  if ! lxc_running "$c"; then
    if [ "$MOUNTED_NOW" = 1 ]; then log "starting LXC $c"; lxc-start -n "$c"; fi
  elif ! lxc_sees_media "$c"; then
    log "LXC $c started before the mount: restarting it"; lxc-stop -n "$c"; lxc-start -n "$c"
  fi
done
