#!/bin/bash
# baseline.sh — baseline for every Ubuntu host in home0ps. Idempotent.
#
#   sudo ./baseline.sh                      # apply all sections, then verify
#   sudo ./baseline.sh --dry-run            # show what would change
#   sudo ./baseline.sh --verify             # only run the checks
#   sudo ./baseline.sh --only snap,updates  # run a subset
#   sudo ./baseline.sh --skip tailscale
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/baseline.sh | sudo bash -s -- --dry-run
#
# Sections: snap updates ssh sysctl purge packages tailscale
#
# Settings (environment, optional):
#   REBOOT_TIME=04:00     automatic reboot time for unattended upgrades
#   AUTO_REBOOT=true      false = never reboot automatically
#   TS_TAG=tag:observed   tag printed in the `tailscale up` hint
#   PACKAGES="btop ncdu git tldr curl ca-certificates"
#
# Docker hosts: run docker-host.sh after this.
set -euo pipefail

SECTIONS="snap updates ssh sysctl purge packages tailscale"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
AUTO_REBOOT="${AUTO_REBOOT:-true}"
TS_TAG="${TS_TAG:-tag:observed}"
PACKAGES="${PACKAGES:-btop ncdu git tldr curl ca-certificates}"
PURGE="avahi-daemon cups cups-browsed bluez modemmanager triggerhappy popularity-contest"
ADMIN_USER="${SUDO_USER:-${LOCAL_UNIX_ACCOUNT:-}}"

# ---- framework --------------------------------------------------------------
MODE=apply; ONLY=""; SKIP=""; FORCE_SSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --verify) MODE=verify ;;
    --only) ONLY="${2:?--only needs a list}"; shift ;;
    --skip) SKIP="${2:?--skip needs a list}"; shift ;;
    --force-ssh) FORCE_SSH=1 ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi
if ! grep -qi '^ID=ubuntu' /etc/os-release; then
  echo "Not Ubuntu (see /etc/os-release)." 1>&2
  exit 1
fi

FAILS=0
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32mOK\e[0m   %s\n' "$*"; }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
run()  { echo "  + $*"; [ "$MODE" = dry ] || "$@"; }
put()  { # put <file> <mode>; content on stdin
  if [ "$MODE" = dry ]; then echo "  + write $1"; cat >/dev/null; else install -D -m "$2" /dev/stdin "$1"; echo "  wrote $1"; fi
}
wanted() {
  case ",$SKIP," in *",$1,"*) return 1 ;; esac
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}
installed() { dpkg -s "$1" >/dev/null 2>&1; }
APT_UPDATED=0
apt_install() {
  local missing=""
  for p in "$@"; do if ! installed "$p"; then missing="$missing $p"; fi; done
  if [ -z "$missing" ]; then return 0; fi
  if [ "$APT_UPDATED" = 0 ] && [ "$MODE" != dry ]; then apt-get update -q; APT_UPDATED=1; fi
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing
}

# ---- snap: remove completely and pin snapd out ------------------------------
apply_snap() {
  step "snap: remove all snaps, purge snapd, pin it out"
  if command -v snap >/dev/null 2>&1; then
    local pass s apps bases
    for pass in 1 2 3 4 5; do
      apps=""; bases=""
      for s in $(snap list 2>/dev/null | awk 'NR>1 {print $1}'); do
        case "$s" in snapd|bare|core|core[0-9]*) bases="$bases $s" ;; *) apps="$apps $s" ;; esac
      done
      if [ -z "$apps$bases" ]; then break; fi
      for s in $apps; do run snap remove --purge "$s" || true; done
      for s in $bases; do [ "$s" = snapd ] || run snap remove --purge "$s" || true; done
      if [ "$(snap list 2>/dev/null | awk 'NR>1 {print $1}')" = snapd ]; then run snap remove --purge snapd || true; fi
      if [ "$MODE" = dry ]; then break; fi
    done
  fi
  local u p pkgs=""
  for u in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then run systemctl disable --now "$u" || true; fi
  done
  for p in snapd gnome-software-plugin-snap; do if installed "$p"; then pkgs="$pkgs $p"; fi; done
  if [ -n "$pkgs" ]; then
    # shellcheck disable=SC2086
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs
  fi
  for u in $(awk '$2 ~ "^/snap/" {print $2}' /proc/mounts 2>/dev/null | sort -r); do run umount -l "$u" || true; done
  for u in /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /root/snap /home/*/snap; do
    if [ -e "$u" ]; then run rm -rf "$u"; fi
  done
  put /etc/apt/preferences.d/no-snapd.pref 644 <<'PREF'
# baseline.sh: block snapd (and debs that only wrap a snap)
Package: snapd
Pin: release a=*
Pin-Priority: -10
PREF
}
verify_snap() {
  command -v snap >/dev/null 2>&1 && bad "snap command present" || ok "no snap command"
  installed snapd && bad "snapd installed" || ok "snapd not installed"
  apt-cache policy snapd 2>/dev/null | grep -q 'Candidate: (none)' && ok "snapd pinned out" || bad "snapd installable"
}

# ---- updates: unattended upgrades + automatic reboot ------------------------
apply_updates() {
  step "updates: unattended upgrades, reboot=$AUTO_REBOOT at $REBOOT_TIME"
  apt_install unattended-upgrades
  put /etc/apt/apt.conf.d/52unattended-local 644 <<CONF
// baseline.sh (home0ps): overrides 50unattended-upgrades. Docker CE: 53unattended-docker (docker-host.sh).
Unattended-Upgrade::Origins-Pattern {
  "origin=Ubuntu,archive=\${distro_codename}-security,label=Ubuntu";
  "origin=Ubuntu,archive=\${distro_codename}-updates,label=Ubuntu";
  "origin=UbuntuESMApps,archive=\${distro_codename}-apps-security";
  "origin=UbuntuESM,archive=\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::SyslogEnable "true";
CONF
  put /etc/apt/apt.conf.d/20auto-upgrades 644 <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
  local t
  for t in apt-daily.timer apt-daily-upgrade.timer; do run systemctl enable --now "$t" || true; done
}
verify_updates() {
  installed unattended-upgrades && ok "unattended-upgrades installed" || bad "unattended-upgrades missing"
  apt-config dump 2>/dev/null | grep -q "Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\"" \
    && ok "config active (reboot $AUTO_REBOOT at $REBOOT_TIME)" || bad "unattended config not active"
  local t
  for t in apt-daily.timer apt-daily-upgrade.timer; do
    systemctl is-enabled --quiet "$t" 2>/dev/null && ok "$t enabled" || bad "$t not enabled"
  done
  unattended-upgrade --dry-run >/dev/null 2>&1 && ok "unattended-upgrade dry run" || bad "unattended-upgrade dry run failed"
}

# ---- ssh: keys only (refuses without a key unless --force-ssh) --------------
apply_ssh() {
  step "ssh: keys only, no root, no forwarding"
  local home keys
  home=$(getent passwd "${ADMIN_USER:-root}" | cut -d: -f6)
  keys="${home:-/nonexistent}/.ssh/authorized_keys"
  if [ "$FORCE_SSH" = 0 ] && ! grep -qsE '^(ssh-|ecdsa-|sk-)' "$keys"; then
    bad "no SSH key in $keys for '${ADMIN_USER:-root}' — not disabling passwords (lockout). Add a key or use --force-ssh"
    return 0
  fi
  put /etc/ssh/sshd_config.d/10-hardening.conf 644 <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
CONF
  if [ "$MODE" != dry ]; then
    if ! sshd -t; then bad "sshd config test failed — not reloading"; return 0; fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh || true
  fi
}
verify_ssh() {
  sshd -T 2>/dev/null | grep -qx 'permitrootlogin no' && ok "SSH root login off" || bad "PermitRootLogin"
  sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' && ok "SSH passwords off" || bad "PasswordAuthentication"
}

# ---- sysctl: kernel hardening (same values as the Pi) -----------------------
apply_sysctl() {
  step "sysctl: kernel hardening"
  put /etc/sysctl.d/99-hardening.conf 644 <<'CONF'
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
CONF
  if [ "$MODE" != dry ]; then sysctl --system >/dev/null; fi
}
verify_sysctl() {
  [ "$(sysctl -n kernel.kptr_restrict)" = 2 ] && ok "kptr_restrict=2" || bad "kptr_restrict"
  [ "$(sysctl -n kernel.dmesg_restrict)" = 1 ] && ok "dmesg_restrict=1" || bad "dmesg_restrict"
  [ "$(sysctl -n kernel.unprivileged_bpf_disabled)" -ge 1 ] && ok "unprivileged BPF off" || bad "unprivileged_bpf_disabled"
}

# ---- purge: packages a server doesn't need ----------------------------------
apply_purge() {
  step "purge: $PURGE"
  local p pkgs=""
  for p in $PURGE; do if installed "$p"; then pkgs="$pkgs $p"; fi; done
  if [ -n "$pkgs" ]; then
    # shellcheck disable=SC2086
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs
    run apt-get autoremove -y --purge
  else
    echo "  nothing to purge"
  fi
}
verify_purge() {
  local p left=""
  for p in $PURGE; do if installed "$p"; then left="$left $p"; fi; done
  [ -z "$left" ] && ok "no unneeded packages" || bad "still installed:$left"
}

# ---- packages: admin tools --------------------------------------------------
apply_packages() { step "packages: $PACKAGES"; # shellcheck disable=SC2086
  apt_install $PACKAGES; }
verify_packages() {
  local p missing=""
  for p in $PACKAGES; do if ! installed "$p"; then missing="$missing $p"; fi; done
  [ -z "$missing" ] && ok "admin packages installed" || bad "missing:$missing"
}

# ---- tailscale: install only; joining is interactive ------------------------
apply_tailscale() {
  step "tailscale: install (login is interactive)"
  if command -v tailscale >/dev/null 2>&1; then
    echo "  already installed"
  elif [ "$MODE" = dry ]; then
    echo "  + curl -fsSL https://tailscale.com/install.sh | sh"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  echo "  Next: sudo tailscale up --advertise-tags=${TS_TAG}   (no --ssh, no --accept-routes)"
}
verify_tailscale() {
  command -v tailscale >/dev/null 2>&1 && ok "tailscale installed" || { bad "tailscale missing"; return 0; }
  tailscale status --self --json 2>/dev/null | grep -q "\"${TS_TAG}\"" && ok "tagged ${TS_TAG}" || bad "not tagged ${TS_TAG} (yet)"
}

# ---- main -------------------------------------------------------------------
for s in $SECTIONS; do
  wanted "$s" || continue
  if [ "$MODE" != verify ]; then "apply_$s"; fi
done
if [ "$MODE" = dry ]; then printf '\nDry run, nothing changed.\n'; exit 0; fi
step "verify"
for s in $SECTIONS; do if wanted "$s"; then "verify_$s"; fi; done
echo; [ "$FAILS" -eq 0 ] && echo "All checks passed." || { echo "$FAILS check(s) failed."; exit 1; }
