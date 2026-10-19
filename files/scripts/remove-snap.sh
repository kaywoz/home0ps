#!/bin/bash
# remove-snap.sh — remove snap completely from an Ubuntu host and keep it out.
#   sudo ./remove-snap.sh            # remove everything (safe to re-run)
#   sudo ./remove-snap.sh --dry-run  # only show what would be done
#
# Order matters: snaps depend on base snaps (core*, bare, snapd), so apps go
# first, bases after, snapd last. Then the snapd package is purged, leftover
# directories are removed and apt is pinned so nothing pulls snapd back in
# (on desktops e.g. the firefox/chromium "transitional" debs would).
set -euo pipefail

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi
run() { echo "+ $*"; [ "$DRY_RUN" = 1 ] || "$@"; }

installed_snaps() { snap list 2>/dev/null | awk 'NR>1 {print $1}'; }
is_base() { case "$1" in snapd|bare|core|core[0-9]*) return 0 ;; *) return 1 ;; esac; }

if command -v snap >/dev/null 2>&1; then
  echo "== Removing snaps"
  # A few passes: removing an app can free a base that was still in use.
  for pass in 1 2 3 4 5; do
    snaps=$(installed_snaps)
    [ -z "$snaps" ] && break
    apps=""; bases=""
    for s in $snaps; do
      if is_base "$s"; then bases="$bases $s"; else apps="$apps $s"; fi
    done
    for s in $apps; do run snap remove --purge "$s" || true; done
    # bases except snapd itself, then snapd once nothing else is left
    for s in $bases; do [ "$s" = snapd ] || run snap remove --purge "$s" || true; done
    if [ "$(installed_snaps)" = "snapd" ]; then run snap remove --purge snapd || true; fi
    [ "$DRY_RUN" = 1 ] && break
    echo "   pass $pass done, left: $(installed_snaps | tr '\n' ' ')"
  done
else
  echo "== snap command not found, skipping snap removal"
fi

echo "== Stopping and purging snapd"
for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    run systemctl disable --now "$unit" || true
  fi
done
# purge only what is installed (unknown package names make apt-get fail)
pkgs=""
for p in snapd gnome-software-plugin-snap; do
  if dpkg -s "$p" >/dev/null 2>&1; then pkgs="$pkgs $p"; fi
done
if [ -n "$pkgs" ]; then
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs
  run apt-get autoremove -y --purge
fi

echo "== Removing leftover mounts and directories"
# Any squashfs mounts that survived (normally gone with the snaps)
for m in $(awk '$2 ~ "^/snap/" {print $2}' /proc/mounts | sort -r); do
  run umount -l "$m" || true
done
for d in /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /root/snap /home/*/snap; do
  if [ -e "$d" ]; then run rm -rf "$d"; fi
done

echo "== Pinning snapd so apt never installs it again"
pin=/etc/apt/preferences.d/no-snapd.pref
if [ "$DRY_RUN" = 1 ]; then
  echo "+ write $pin"
else
  cat > "$pin" <<'PREF'
# Installed by remove-snap.sh: block snapd (and debs that only wrap a snap)
Package: snapd
Pin: release a=*
Pin-Priority: -10
PREF
fi

echo "== Verify"
if [ "$DRY_RUN" = 1 ]; then
  echo "   dry run, nothing changed"
else
  command -v snap >/dev/null 2>&1 && echo "   WARN: snap command still present" || echo "   OK: snap command gone"
  dpkg -s snapd >/dev/null 2>&1 && echo "   WARN: snapd package still installed" || echo "   OK: snapd package purged"
  apt-cache policy snapd | grep -q 'Candidate: (none)' && echo "   OK: snapd pinned (no install candidate)" || echo "   WARN: snapd still installable — check $pin"
fi
