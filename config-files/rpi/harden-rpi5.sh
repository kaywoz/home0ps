#!/usr/bin/env bash
# harden-rpi5.sh — idempotent host hardening for a monitoring host (Raspberry Pi 5, Raspberry Pi OS Lite 64-bit).
# Usage:  sudo TS_TAILNET_DNS=<tailnet>.ts.net ./harden-rpi5.sh   # apply everything (safe to re-run)
#         sudo ./harden-rpi5.sh --verify                          # only run the checks
# After the first run: reboot, then run --verify.
# If run as root without sudo, set LOCAL_UNIX_ACCOUNT to the admin account that joins the docker group.
set -euo pipefail

# ---- settings -------------------------------------------------------------
TS_TAG="tag:monitoring"
DOCKER_ROOT="/srv/docker"
ADMIN_USER="${SUDO_USER:-${LOCAL_UNIX_ACCOUNT:?set LOCAL_UNIX_ACCOUNT or run via sudo}}"
INSTALL_COCKPIT=1
COCKPIT_LOCAL_PORT=9091
COCKPIT_SVC_HOST="cockpit.${TS_TAILNET_DNS:-}" # tailnet DNS name kept out of git; required by apply when INSTALL_COCKPIT=1
LOCALE="en_US.UTF-8"
REBOOT_TIME="04:00"
# ---------------------------------------------------------------------------

CFG=/boot/firmware/config.txt
CMDLINE=/boot/firmware/cmdline.txt
NEED_REBOOT=0
ok()   { printf '  \e[32mOK\e[0m   %s\n' "$*"; }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

apply() {
  step "Firmware: radios and UART off (Pi 5 overlay names)"
  grep -q '^\[all\]' "$CFG" || printf '\n[all]\n' >> "$CFG"
  for line in "dtoverlay=disable-wifi-pi5" "dtoverlay=disable-bt-pi5" "enable_uart=0"; do
    grep -qxF "$line" "$CFG" || { echo "$line" >> "$CFG"; NEED_REBOOT=1; echo "  added $line"; }
  done

  step "Kernel cmdline: enable memory cgroup (mem_limit support)"
  grep -q 'cgroup_enable=memory' "$CMDLINE" || { sed -i '1 s/$/ cgroup_enable=memory/' "$CMDLINE"; NEED_REBOOT=1; echo "  added cgroup_enable=memory"; }

  step "Packages: update, remove what a monitoring box doesn't need"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -q avahi-daemon 'cups*' bluez wpasupplicant triggerhappy 2>/dev/null || true
  apt-get autoremove -y -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades apache2-utils curl ca-certificates locales

  step "Locale ($LOCALE) — avoids setlocale warnings over SSH"
  sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
  locale-gen >/dev/null

  step "Unattended upgrades (Debian + Raspberry Pi), auto reboot $REBOOT_TIME"
  cat > /etc/apt/apt.conf.d/52unattended-local <<CONF
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=\${distro_codename},label=Debian-Security";
  "origin=Debian,codename=\${distro_codename}";
  "origin=Raspberry Pi Foundation,codename=\${distro_codename}";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
CONF
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

  step "Kernel sysctls"
  cat > /etc/sysctl.d/99-hardening.conf <<'CONF'
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
CONF
  sysctl --system >/dev/null

  step "SSH: keys only, no root"
  cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
CONF
  sshd -t && systemctl restart ssh

  if [ "$INSTALL_COCKPIT" = 1 ]; then
    step "Cockpit: localhost only, behind svc:cockpit"
    : "${TS_TAILNET_DNS:?set TS_TAILNET_DNS to the tailnet DNS name (<tailnet>.ts.net)}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q cockpit
    mkdir -p /etc/systemd/system/cockpit.socket.d
    cat > /etc/systemd/system/cockpit.socket.d/listen.conf <<CONF
[Socket]
ListenStream=
ListenStream=127.0.0.1:${COCKPIT_LOCAL_PORT}
CONF
    cat > /etc/cockpit/cockpit.conf <<CONF
[WebService]
Origins = https://${COCKPIT_SVC_HOST} wss://${COCKPIT_SVC_HOST}
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
LoginTo = false
CONF
    grep -qx root /etc/cockpit/disallowed-users 2>/dev/null || echo root >> /etc/cockpit/disallowed-users
    systemctl daemon-reload && systemctl restart cockpit.socket
  fi

  step "Docker + daemon.json (userns-remap)"
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$ADMIN_USER"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'CONF'
{
  "userns-remap": "default",
  "no-new-privileges": true,
  "icc": false,
  "userland-proxy": false,
  "live-restore": true,
  "log-driver": "local",
  "log-opts": { "max-size": "10m" }
}
CONF
  systemctl restart docker
  mkdir -p "$DOCKER_ROOT" && chown "$ADMIN_USER": "$DOCKER_ROOT"

  step "Tailscale (install only — login is interactive)"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  echo "  Next: sudo tailscale up --advertise-tags=${TS_TAG}   (no --ssh, no --accept-routes)"

  step "Boot order: NVMe only (only if currently booted from NVMe)"
  if findmnt -no SOURCE / | grep -q nvme; then
    cur=$(rpi-eeprom-config | sed -n 's/^BOOT_ORDER=//p')
    if [ "$cur" != "0xf6" ]; then
      rpi-eeprom-config > /tmp/boot.conf
      if grep -q '^BOOT_ORDER=' /tmp/boot.conf; then sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf6/' /tmp/boot.conf; else echo 'BOOT_ORDER=0xf6' >> /tmp/boot.conf; fi
      rpi-eeprom-config --apply /tmp/boot.conf && NEED_REBOOT=1
    else echo "  already 0xf6"; fi
  else echo "  not booted from NVMe — skipped"; fi

  step "Done"
  [ "$NEED_REBOOT" = 1 ] && echo "  Reboot required, then run: sudo $0 --verify"
}

verify() {
  FAILS=0
  step "Verify"
  ! ip link show wlan0 >/dev/null 2>&1                      && ok "no wlan0"            || bad "wlan0 present (overlay/reboot?)"
  [ -z "$(ls /sys/class/bluetooth 2>/dev/null)" ]           && ok "no Bluetooth"        || bad "Bluetooth present"
  grep -q cgroup_enable=memory /proc/cmdline                && ok "memory cgroup on"    || bad "memory cgroup off (reboot?)"
  [ "$(sysctl -n kernel.kptr_restrict)" = 2 ]               && ok "kptr_restrict=2"     || bad "kptr_restrict"
  [ "$(sysctl -n kernel.unprivileged_bpf_disabled)" -ge 1 ] && ok "unpriv BPF disabled" || bad "unprivileged_bpf_disabled"
  sshd -T | grep -qx 'permitrootlogin no'                   && ok "SSH root login off"  || bad "PermitRootLogin"
  sshd -T | grep -qx 'passwordauthentication no'            && ok "SSH passwords off"   || bad "PasswordAuthentication"
  docker info 2>/dev/null | grep -q 'userns'                && ok "Docker userns-remap" || bad "userns-remap not active"
  docker info 2>&1 | grep -qi 'no memory limit support'     && bad "Docker memory limits unsupported" || ok "Docker memory limits"
  if command -v tailscale >/dev/null; then
    tailscale status --self --json 2>/dev/null | grep -q "\"${TS_TAG}\"" && ok "tailnet tag ${TS_TAG}" || bad "tag ${TS_TAG} missing"
    tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": false' && ok "Tailscale SSH off" || bad "Tailscale SSH on?"
  fi
  if [ "$INSTALL_COCKPIT" = 1 ]; then
    ss -tln | grep -q "127.0.0.1:${COCKPIT_LOCAL_PORT}" && ok "Cockpit on localhost:${COCKPIT_LOCAL_PORT}" || bad "Cockpit listener"
    ss -tln | grep -qE '(0\.0\.0\.0|\*|\[::\]):9090' && bad "something listens on 9090 publicly" || ok "nothing public on 9090"
  fi
  echo "  Listening on non-loopback, non-tailnet addresses (expect only sshd :22):"
  ss -tlnH | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|100\.|\[fd7a:|172\.31\.250\.1)' | sed 's/^/    /'
  [ "$(rpi-eeprom-config | sed -n 's/^BOOT_ORDER=//p')" = 0xf6 ] && ok "BOOT_ORDER=0xf6" || bad "BOOT_ORDER not NVMe-only"
  echo; [ "$FAILS" -eq 0 ] && echo "All checks passed." || echo "$FAILS check(s) failed."
}

case "${1:-}" in
  --verify) verify ;;
  *) apply; verify || true ;;
esac
