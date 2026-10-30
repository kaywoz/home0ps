#!/bin/bash
# create-lxc.sh — create an unprivileged guest LXC on the MOS host (Devuan, classic LXC).
# Encodes what the nesting test showed (kaywoz/home0ps#174):
#   * unprivileged from the start: lxc-create -f <conf> with the idmap lines (the download template
#     adds common.conf + userns.conf itself); the image unpacks with shifted ownership — no chown.
#     The idmap MUST be there at creation; other lines (net, limits, tun, gpu) can be edited later,
#     e.g. in MOS's container config editor.
#   * MOS's LXC is built WITHOUT AppArmor: no nesting.conf include, only its proc/sys mount entries
#   * Docker works inside (overlayfs, cgroup v2, DOCKER-USER chain)
#   * no bridges on MOS: networking via macvlan on the guest's VLAN interface
#
# Usage (as root on MOS):
#   ./create-lxc.sh -n <name> -l <iface> [-m 8G] [-c 2] [-r noble] [--gpu] [--autostart] [--dry-run]
#
#   -n NAME       container name, e.g. media (infra and apps are VMs, not LXCs — kaywoz/home0ps#174)
#   -l IFACE      parent interface for macvlan = the guest's VLAN, e.g. bond0.13 (one VLAN per guest)
#   -m MEM        memory limit (cgroup v2 memory.max), default 4G
#   -c CPUS       CPU limit in cores (cgroup v2 cpu.max), default 2
#   -r RELEASE    Ubuntu release for the download template, default noble
#   --gpu         pass /dev/dri (iGPU) into the guest and map the host's render group (media LXC).
#                 UNTESTED on MOS — verify with a transcode before relying on it
#   --autostart   lxc.start.auto = 1 (check that MOS starts LXCs at boot)
#   --dry-run     print the config and steps, change nothing
#
# Example (media LXC on VLAN 13):
#   ./create-lxc.sh -n media -l bond0.13 -m 6G -c 2 --gpu --autostart --dry-run
#   ./create-lxc.sh -n media -l bond0.13 -m 6G -c 2 --gpu --autostart
#
# Next steps inside the guest (printed at the end): baseline.sh, then docker-host.sh —
# both detect the container and skip what can't work there (sysctl, userns-remap).
set -euo pipefail

NAME=""; LINK=""; MEM=4G; CPUS=2; RELEASE=noble; GPU=0; AUTOSTART=0; DRY=0
UIDBASE=100000; UIDRANGE=65536
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NAME="${2:?}"; shift ;;
    -l) LINK="${2:?}"; shift ;;
    -m) MEM="${2:?}"; shift ;;
    -c) CPUS="${2:?}"; shift ;;
    -r) RELEASE="${2:?}"; shift ;;
    --gpu) GPU=1 ;;
    --autostart) AUTOSTART=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
for f in /etc/subuid /etc/subgid; do
  grep -qE "^root:${UIDBASE}:${UIDRANGE}$" "$f" 2>/dev/null || die "root:${UIDBASE}:${UIDRANGE} missing in $f"
done
ip link show "$LINK" >/dev/null 2>&1 || die "interface $LINK does not exist — create the VLAN interface on MOS first (persistently)"
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
  # split the gid map so container gid RG = host gid RG (needs root:RG:1 in /etc/subgid)
  IDMAP_G="lxc.idmap = g 0 ${UIDBASE} ${RG}
lxc.idmap = g ${RG} ${RG} 1
lxc.idmap = g $((RG+1)) $((UIDBASE+RG+1)) $((UIDRANGE-RG-1))"
  GPU_CONF="# iGPU for hardware transcoding (render group ${RG} mapped 1:1)
lxc.cgroup2.devices.allow = c 226:* rwm
lxc.mount.entry = /dev/dri dev/dri none bind,optional,create=dir"
fi

CONF=$(cat <<EOF
# created by create-lxc.sh (home0ps) for '${NAME}'
# (common.conf + userns.conf are added by the download template itself)
lxc.idmap = u 0 ${UIDBASE} ${UIDRANGE}
${IDMAP_G}
# nesting (Docker inside) — nesting.conf minus its AppArmor line (MOS LXC has no AppArmor)
lxc.mount.entry = proc dev/.lxc/proc proc create=dir,optional 0 0
lxc.mount.entry = sys dev/.lxc/sys sysfs create=dir,optional 0 0
# network: macvlan on the guest's VLAN interface (MOS has no bridges)
lxc.net.0.type = macvlan
lxc.net.0.link = ${LINK}
lxc.net.0.macvlan.mode = bridge
lxc.net.0.flags = up
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

echo "== ${NAME}: Ubuntu ${RELEASE}, ${CPUS} cores, ${MEM}, macvlan on ${LINK}$( [ "$GPU" = 1 ] && echo ', iGPU' ), lxcpath ${P}"
if [ "$DRY" = 1 ]; then
  echo "--- config ---"; echo "$CONF"; echo "--------------"
  [ "$GPU" = 1 ] && echo "+ ensure 'root:${RG}:1' in /etc/subgid"
  echo "+ lxc-create -n ${NAME} -f <config> -t download -- -d ubuntu -r ${RELEASE} -a amd64"
  echo "+ chmod o+x ${P} ${P}/${NAME}; lxc-start; wait for network; apt-get install curl ca-certificates"
  echo "Dry run, nothing changed."; exit 0
fi

# ---- create -------------------------------------------------------------------
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
echo "$CONF" > "$TMP"
if [ "$GPU" = 1 ] && ! grep -qx "root:${RG}:1" /etc/subgid; then
  echo "root:${RG}:1" >> /etc/subgid; echo "  added root:${RG}:1 to /etc/subgid (render group passthrough)"
fi
lxc-create -n "$NAME" -f "$TMP" -t download -- -d ubuntu -r "$RELEASE" -a amd64
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
lxc-attach -n "$NAME" -- ip -br addr show eth0 | sed 's/^/  /'
if lxc-attach -n "$NAME" -- test -c /dev/net/tun; then echo "  OK   /dev/net/tun available (Tailscale)"; else echo "  FAIL /dev/net/tun missing in the guest"; fi
if [ "$GPU" = 1 ]; then
  if lxc-attach -n "$NAME" -- test -e /dev/dri/renderD128; then
    echo "  OK   /dev/dri/renderD128 visible: $(lxc-attach -n "$NAME" -- stat -c '%U:%G %a' /dev/dri/renderD128)"
  else echo "  FAIL /dev/dri/renderD128 not visible in the guest"; fi
fi

lxc-attach -n "$NAME" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null && apt-get install -y -q curl ca-certificates >/dev/null' \
  && echo "  OK   curl + ca-certificates installed" || echo "  WARN apt failed (no network yet?)"

cat <<MSG

Done: ${NAME}. Next, inside the guest (lxc-attach -n ${NAME}):
  curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/baseline.sh | bash -s -- --dry-run
  curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/docker-host.sh | bash -s -- --dry-run
Both detect the container and skip sysctl / userns-remap. Then: tailscale up --advertise-tags=<tag for this guest>.
MSG
