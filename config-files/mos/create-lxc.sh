#!/bin/bash
# create-lxc.sh — create an unprivileged guest LXC on the MOS host (Devuan, classic LXC).
# Encodes what the nesting test showed (kaywoz/home0ps#174):
#   * unprivileged from the start: lxc-create -f <conf> with the idmap lines (the download template
#     adds common.conf + userns.conf itself); the image unpacks with shifted ownership — no chown.
#     The idmap MUST be there at creation; other lines (net, limits, tun, gpu) can be edited later,
#     e.g. in MOS's container config editor.
#   * MOS's LXC is built WITHOUT AppArmor: no nesting.conf include, only its proc/sys mount entries
#   * MOS's LXC (7.0.0, cgroup v2): device rules placed AFTER the common.conf include replace its
#     allowlist (/dev/null etc. get blocked, systemd fails, no DHCP). The script moves its own device
#     lines above that include after lxc-create (tested 2026-11-02, kaywoz/home0ps#174)
#   * Docker works inside (overlayfs, cgroup v2, DOCKER-USER chain)
#   * no bridges on MOS: one port per guest (kaywoz/home0ps#174). Default: the whole port moves
#     into the guest (lxc.net type phys); the switch port is an access port on the guest's VLAN.
#     macvlan on a VLAN interface is the fallback if phys fails on MOS.
#
# Usage (as root on MOS):
#   ./create-lxc.sh -n <name> -l <iface> [-t phys|macvlan] [-m 8G] [-c 2] [-d debian] [-r trixie] [--gpu]
#                   [--autostart] [--dry-run]
#
#   -n NAME       container name, e.g. media (infra and apps are VMs, not LXCs — kaywoz/home0ps#174)
#   -l IFACE      phys: the guest's own port, e.g. eth2 (the host loses it while the guest runs)
#                 macvlan: parent interface on the guest's VLAN, e.g. eth2.13
#   -t TYPE       phys (default) or macvlan. phys is UNTESTED on MOS — verify before relying on it
#   -m MEM        memory limit (cgroup v2 memory.max), default 4G
#   -c CPUS       CPU limit in cores (cgroup v2 cpu.max), default 2
#   -d DIST       distribution for the download template, default debian (kaywoz, 2026-11-02)
#   -r RELEASE    release for the download template, default trixie (Debian 13)
#   --gpu         pass /dev/dri (iGPU) into the guest and map the host's render group (media LXC).
#                 UNTESTED on MOS — verify with a transcode before relying on it
#   --autostart   lxc.start.auto = 1 (check that MOS starts LXCs at boot)
#   --dry-run     print the config and steps, change nothing
#
# Example (media LXC on its own port, switch port = access VLAN 13):
#   ./create-lxc.sh -n media -l eth2 -m 6G -c 2 --gpu --autostart --dry-run
#   ./create-lxc.sh -n media -l eth2 -m 6G -c 2 --gpu --autostart
#
# Next steps inside the guest (printed at the end): baseline.sh, then docker-host.sh —
# both detect the container and skip what can't work there (sysctl, userns-remap).
# Both handle Debian and Ubuntu, and ask for the admin account when run as root.
#
# Id maps: as root, LXC writes the uid/gid maps itself unless shadow's newuidmap/newgidmap are
# installed (lxc src/lxc/idmap_utils.c, lxc_map_ids). MOS has neither, so /etc/subuid and
# /etc/subgid aren't consulted (and /etc is rebuilt at boot anyway): the script only checks and
# extends them when those tools exist.
set -euo pipefail

NAME=""; LINK=""; NETTYPE=phys; MEM=4G; CPUS=2; DIST=debian; RELEASE=trixie; GPU=0; AUTOSTART=0; DRY=0
UIDBASE=100000; UIDRANGE=65536
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NAME="${2:?}"; shift ;;
    -l) LINK="${2:?}"; shift ;;
    -t) NETTYPE="${2:?}"; shift ;;
    -m) MEM="${2:?}"; shift ;;
    -c) CPUS="${2:?}"; shift ;;
    -d) DIST="${2:?}"; shift ;;
    -r) RELEASE="${2:?}"; shift ;;
    --gpu) GPU=1 ;;
    --autostart) AUTOSTART=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

die() { echo "ABORT (nothing changed): $*" >&2; exit 1; }

# ---- prechecks: abort before any change ---------------------------------------
[ "$(id -u)" = 0 ] || die "run as root"
[ -n "$NAME" ] && [ -n "$LINK" ] || die "-n NAME and -l IFACE are required (see --help)"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "name must be lowercase letters/digits/-, 2-31 chars"
command -v lxc-create >/dev/null || die "lxc-create not found"
P=$(lxc-config lxc.lxcpath)
lxc-info -n "$NAME" >/dev/null 2>&1 && die "container '$NAME' already exists"
SHADOW_IDMAP=0
if command -v newuidmap >/dev/null 2>&1 && command -v newgidmap >/dev/null 2>&1; then
  SHADOW_IDMAP=1
  for f in /etc/subuid /etc/subgid; do
    grep -E "^root:${UIDBASE}:${UIDRANGE}$" "$f" >/dev/null 2>&1 || die "root:${UIDBASE}:${UIDRANGE} missing in $f (newuidmap/newgidmap installed, so LXC needs it)"
  done
fi
[ "$NETTYPE" = phys ] || [ "$NETTYPE" = macvlan ] || die "-t must be phys or macvlan"
ip link show "$LINK" >/dev/null 2>&1 || die "interface $LINK does not exist"
if [ "$NETTYPE" = phys ]; then
  # phys takes the port away from the host: never the one MOS itself is reached on
  ip route show default | grep -w "dev $LINK" >/dev/null && die "$LINK carries the host's default route — phys would cut MOS off"
  ip -o link show | grep "@${LINK}:" >/dev/null && die "$LINK has VLAN/child interfaces on the host — phys would take them down; remove them first"
  ip -4 -o addr show dev "$LINK" | grep inet >/dev/null \
    && echo "WARN: $LINK has an address on the host ($(ip -4 -o addr show dev "$LINK" | awk '{print $4}' | head -1)) — it moves into the guest with the port"
fi
ip -br link show "$LINK" | grep -E '\bUP\b' >/dev/null || echo "WARN: $LINK is not UP — the guest will have no network until it is"
[[ "$MEM" =~ ^[0-9]+[KMG]$ ]] || die "-m must look like 4G / 512M"
[[ "$CPUS" =~ ^[0-9]+$ ]] && [ "$CPUS" -ge 1 ] || die "-c must be a whole number of cores"
for f in common.conf userns.conf; do [ -f "/usr/share/lxc/config/$f" ] || die "/usr/share/lxc/config/$f missing"; done
[ -c /dev/net/tun ] || die "/dev/net/tun missing on the host (needed for Tailscale in the guest)"

# ---- GPU: map the host's render group 1:1 into the guest ----------------------
GPU_CONF=""; IDMAP_G="lxc.idmap = g 0 ${UIDBASE} ${UIDRANGE}"
if [ "$GPU" = 1 ]; then
  [ -e /dev/dri/renderD128 ] || die "--gpu: /dev/dri/renderD128 not found"
  RG=$(stat -c %g /dev/dri/renderD128)
  [ "$RG" -gt 0 ] && [ "$RG" -lt "$UIDRANGE" ] || die "--gpu: render group id $RG out of range"
  # split the gid map so container gid RG = host gid RG (root:RG:1 in /etc/subgid only with newgidmap)
  IDMAP_G="lxc.idmap = g 0 ${UIDBASE} ${RG}
lxc.idmap = g ${RG} ${RG} 1
lxc.idmap = g $((RG+1)) $((UIDBASE+RG+1)) $((UIDRANGE-RG-1))"
  GPU_CONF="# iGPU for hardware transcoding (render group ${RG} mapped 1:1)
lxc.cgroup2.devices.allow = c 226:* rwm
lxc.mount.entry = /dev/dri dev/dri none bind,optional,create=dir"
fi

MACVLAN_MODE=""; [ "$NETTYPE" = macvlan ] && MACVLAN_MODE="lxc.net.0.macvlan.mode = bridge
"

CONF=$(cat <<EOF
# created by create-lxc.sh (home0ps) for '${NAME}'
# (common.conf + userns.conf are added by the download template itself)
lxc.idmap = u 0 ${UIDBASE} ${UIDRANGE}
${IDMAP_G}
# nesting (Docker inside) — nesting.conf minus its AppArmor line (MOS LXC has no AppArmor)
lxc.mount.entry = proc dev/.lxc/proc proc create=dir,optional 0 0
lxc.mount.entry = sys dev/.lxc/sys sysfs create=dir,optional 0 0
# network: ${NETTYPE} on ${LINK} (one port per guest, MOS has no bridges)
lxc.net.0.type = ${NETTYPE}
lxc.net.0.link = ${LINK}
${MACVLAN_MODE}lxc.net.0.flags = up
lxc.net.0.name = eth0
# /dev/net/tun for Tailscale inside the guest (unprivileged LXCs can't mknod)
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file
# resource limits
lxc.cgroup2.memory.max = ${MEM}
lxc.cgroup2.cpu.max = $((CPUS*100000)) 100000
lxc.start.auto = ${AUTOSTART}
${GPU_CONF}
EOF
)

echo "== ${NAME}: ${DIST} ${RELEASE}, ${CPUS} cores, ${MEM}, ${NETTYPE} on ${LINK}$( [ "$GPU" = 1 ] && echo ', iGPU' ), lxcpath ${P}"
if [ "$DRY" = 1 ]; then
  echo "--- config ---"; echo "$CONF"; echo "--------------"
  if [ "$GPU" = 1 ] && [ "$SHADOW_IDMAP" = 1 ]; then echo "+ ensure 'root:${RG}:1' in /etc/subgid"; fi
  [ "$SHADOW_IDMAP" = 1 ] || echo "+ no newuidmap/newgidmap: LXC writes the id maps directly, /etc/subuid + /etc/subgid not needed"
  echo "+ lxc-create -n ${NAME} -f <config> -t download -- -d ${DIST} -r ${RELEASE} -a amd64"
  echo "+ move the lxc.cgroup2.devices lines above the common.conf include in ${P}/${NAME}/config"
  echo "+ chmod o+x ${P} ${P}/${NAME}; lxc-start; wait for network; apt-get install curl ca-certificates"
  echo "Dry run, nothing changed."; exit 0
fi

# ---- create -------------------------------------------------------------------
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
echo "$CONF" > "$TMP"
if [ "$GPU" = 1 ] && [ "$SHADOW_IDMAP" = 1 ] && ! grep -x "root:${RG}:1" /etc/subgid >/dev/null; then
  echo "root:${RG}:1" >> /etc/subgid; echo "  added root:${RG}:1 to /etc/subgid (render group passthrough)"
fi
lxc-create -n "$NAME" -f "$TMP" -t download -- -d "$DIST" -r "$RELEASE" -a amd64

# device rules must come before the common.conf include on MOS (see header)
CFG="$P/$NAME/config"
grep -E '^lxc\.include = .*common\.conf$' "$CFG" >/dev/null || die "no common.conf include in $CFG — check the device rules by hand"
DEVLINES=$(grep '^lxc\.cgroup2\.devices' "$CFG" || true) awk '
  /^lxc\.cgroup2\.devices/ { next }
  /^lxc\.include = .*common\.conf$/ && !done { print ENVIRON["DEVLINES"]; done = 1 }
  { print }' "$CFG" > "$CFG.new" && mv "$CFG.new" "$CFG"
echo "  device rules moved above the common.conf include"
chmod o+x "$P" "$P/$NAME"
lxc-start -n "$NAME"

echo "== waiting for network"
for i in $(seq 30); do
  if lxc-attach -n "$NAME" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then break; fi; sleep 2
done
lxc-attach -n "$NAME" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || { echo "WARN: no network in ${NAME} — check ${LINK} / DHCP on its VLAN"; }

echo "== verify"
MAP=$(lxc-attach -n "$NAME" -- cat /proc/self/uid_map | awk '{print $1, $2, $3}')
[ "$MAP" = "0 ${UIDBASE} ${UIDRANGE}" ] && echo "  OK   unprivileged (uid_map: $MAP)" || echo "  FAIL uid_map is '$MAP' — not unprivileged"
if lxc-attach -n "$NAME" -- sh -c 'echo > /dev/null'; then echo "  OK   /dev/null usable"; else echo "  FAIL /dev/null blocked — device rules order in $CFG"; fi
lxc-attach -n "$NAME" -- ip -br addr show eth0 | sed 's/^/  /'
if lxc-attach -n "$NAME" -- test -c /dev/net/tun; then echo "  OK   /dev/net/tun available (Tailscale)"; else echo "  FAIL /dev/net/tun missing in the guest"; fi
if [ "$GPU" = 1 ]; then
  lxc-attach -n "$NAME" -- cat /proc/self/gid_map | grep -E "^ *${RG} +${RG} +1$" >/dev/null \
    && echo "  OK   render group ${RG} mapped 1:1 (gid_map)" || echo "  FAIL render group ${RG} not mapped 1:1 in gid_map"
  # open without reading (a read on a render node blocks)
  if lxc-attach -n "$NAME" -- sh -c 'exec 3</dev/dri/renderD128'; then
    echo "  OK   /dev/dri/renderD128 opens: $(lxc-attach -n "$NAME" -- stat -c '%U:%G %a' /dev/dri/renderD128)"
  else echo "  FAIL /dev/dri/renderD128 can't be opened in the guest"; fi
fi

lxc-attach -n "$NAME" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null && apt-get install -y -q curl ca-certificates >/dev/null' \
  && echo "  OK   curl + ca-certificates installed" || echo "  WARN apt failed (no network yet?)"

cat <<MSG

Done: ${NAME}. Next, inside the guest (lxc-attach -n ${NAME}):
  curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/baseline.sh | bash -s -- --dry-run
  curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/docker-host.sh | bash -s -- --dry-run
Both detect the container and skip sysctl / userns-remap. Then: tailscale up --advertise-tags=<tag for this guest>.
MSG
