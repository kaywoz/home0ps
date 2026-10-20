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
# Sections: snap updates ssh sysctl purge packages cockpit tailscale
#
# Settings (environment, optional):
#   REBOOT_TIME=04:00     automatic reboot time for unattended upgrades
#   AUTO_REBOOT=true      false = never reboot automatically
#   TS_TAG=tag:observed   tag printed in the `tailscale up` hint
#   COCKPIT_SVC=          Tailscale Service name for this host's Cockpit, e.g. cockpit-apps
#                         (svc:cockpit is the monitoring host). Unset = cockpit section skipped.
#   TS_TAILNET_DNS=       <tailnet>.ts.net, for Cockpit's Origins (needed with COCKPIT_SVC)
#   COCKPIT_MODULES="cockpit-ws cockpit-system cockpit-bridge cockpit-storaged cockpit-packagekit cockpit-files cockpit-sosreport"
#   PACKAGES="htop ncdu git tealdeer|tldr unzip curl ca-certificates"
#            apt packages; "a|b" = first one installable on this release.
#            A package with no install candidate is reported, not fatal.
#   dysk is not in Ubuntu's repos: installed from its GitHub release, checksum-verified
#
# Docker hosts: run docker-host.sh after this.
set -euo pipefail
# Command output is parsed below (apt-cache policy, sshd -T, docker info): force English.
export LC_ALL=C LANG=C

SECTIONS="snap updates ssh sysctl purge packages cockpit tailscale"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
AUTO_REBOOT="${AUTO_REBOOT:-true}"
TS_TAG="${TS_TAG:-tag:observed}"
PACKAGES="${PACKAGES:-htop ncdu git tealdeer|tldr unzip curl ca-certificates}"
COCKPIT_SVC="${COCKPIT_SVC:-}"
TS_TAILNET_DNS="${TS_TAILNET_DNS:-}"
COCKPIT_PORT=9091
# no cockpit-networkmanager (would pull NetworkManager onto netplan/networkd servers),
# no cockpit-pcp (not in 26.04), no machines/podman (Docker hosts, no VMs)
COCKPIT_MODULES="${COCKPIT_MODULES:-cockpit-ws cockpit-system cockpit-bridge cockpit-storaged cockpit-packagekit cockpit-files cockpit-sosreport}"
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
# no `grep -q` after a pipe: it exits early, the writer gets SIGPIPE and pipefail fails the check
has_candidate() { apt-cache policy "$1" 2>/dev/null | grep 'Candidate: [^(]' >/dev/null; }
# apt_install <pkg|alt1|alt2>... : skips installed ones, picks the first installable
# alternative, reports (doesn't abort on) names with no candidate on this release
apt_install() {
  local item alt pick missing=""
  if [ "$APT_UPDATED" = 0 ] && [ "$MODE" != dry ]; then apt-get update -q; APT_UPDATED=1; fi
  for item in "$@"; do
    pick=""
    for alt in ${item//|/ }; do if installed "$alt"; then pick=installed; break; fi; done
    [ "$pick" = installed ] && continue
    for alt in ${item//|/ }; do if has_candidate "$alt"; then pick="$alt"; break; fi; done
    if [ -n "$pick" ]; then missing="$missing $pick"; else bad "no installable package for '$item' on this release"; fi
  done
  if [ -z "$missing" ]; then return 0; fi
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q ${APT_NO_RECOMMENDS:+--no-install-recommends} $missing
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
  apt-cache policy snapd 2>/dev/null | grep 'Candidate: (none)' >/dev/null && ok "snapd pinned out" || bad "snapd installable"
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
  apt-config dump 2>/dev/null | grep "Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\"" >/dev/null \
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
  sshd -T 2>/dev/null | grep -x 'permitrootlogin no' >/dev/null && ok "SSH root login off" || bad "PermitRootLogin"
  sshd -T 2>/dev/null | grep -x 'passwordauthentication no' >/dev/null && ok "SSH passwords off" || bad "PasswordAuthentication"
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
apply_packages() {
  step "packages: $PACKAGES + dysk"
  # shellcheck disable=SC2086
  apt_install $PACKAGES
  install_dysk
  # tealdeer needs its page cache once per user
  if installed tealdeer && [ -n "$ADMIN_USER" ] && [ "$MODE" != dry ]; then
    sudo -u "$ADMIN_USER" -H tldr --update >/dev/null 2>&1 && echo "  tldr pages downloaded for $ADMIN_USER" || echo "  WARN: tldr --update failed (run it as $ADMIN_USER)"
  fi
}
# dysk (disk usage overview) isn't packaged for Ubuntu: latest GitHub release, static musl
# binary, SHA-256 from the GitHub API checked before extracting. Installed once; re-run
# with the binary removed to upgrade (not covered by unattended upgrades).
install_dysk() {
  if command -v dysk >/dev/null 2>&1; then echo "  dysk already installed ($(dysk --version 2>/dev/null | head -1))"; return 0; fi
  local arch meta tag url sha tmp
  case "$(uname -m)" in
    x86_64) arch=x86_64-unknown-linux-musl ;;
    aarch64|arm64) arch=aarch64-unknown-linux-musl ;;
    *) echo "  dysk: no build for $(uname -m), skipped"; return 0 ;;
  esac
  if [ "$MODE" = dry ]; then echo "  + download latest dysk release, verify sha256, install $arch/dysk -> /usr/local/bin/dysk"; return 0; fi
  meta=$(curl -fsSL https://api.github.com/repos/Canop/dysk/releases/latest)
  read -r tag url sha < <(printf '%s' "$meta" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d["assets"][0]; print(d["tag_name"], a["browser_download_url"], (a.get("digest") or "").replace("sha256:",""))')
  if [ -z "$sha" ]; then bad "dysk $tag: no checksum published, not installing"; return 0; fi
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/dysk.zip"
  if ! echo "$sha  $tmp/dysk.zip" | sha256sum -c --quiet -; then bad "dysk $tag: checksum mismatch, not installing"; rm -rf "$tmp"; return 0; fi
  unzip -q -j "$tmp/dysk.zip" "$arch/dysk" -d "$tmp"
  install -m 755 "$tmp/dysk" /usr/local/bin/dysk
  rm -rf "$tmp"
  echo "  installed dysk $tag"
}
verify_packages() {
  local item alt hit missing=""
  for item in $PACKAGES; do
    hit=""
    for alt in ${item//|/ }; do if installed "$alt"; then hit=1; fi; done
    [ -n "$hit" ] || missing="$missing $item"
  done
  [ -z "$missing" ] && ok "admin packages installed" || bad "missing:$missing"
  command -v dysk >/dev/null 2>&1 && ok "dysk installed" || bad "dysk missing"
}

# ---- cockpit: localhost only, published as this host's Tailscale Service ------
apply_cockpit() {
  step "cockpit: ${COCKPIT_MODULES}"
  if [ -z "$COCKPIT_SVC" ] || [ -z "$TS_TAILNET_DNS" ]; then
    echo "  skipped: set COCKPIT_SVC=<service name, e.g. cockpit-apps> and TS_TAILNET_DNS=<tailnet>.ts.net"
    return 0
  fi
  local host="${COCKPIT_SVC}.${TS_TAILNET_DNS}"
  # shellcheck disable=SC2086
  APT_NO_RECOMMENDS=1 apt_install $COCKPIT_MODULES
  put /etc/systemd/system/cockpit.socket.d/listen.conf 644 <<CONF
[Socket]
ListenStream=
ListenStream=127.0.0.1:${COCKPIT_PORT}
CONF
  # TLS ends at tailscale serve; the localhost leg is plain HTTP
  put /etc/cockpit/cockpit.conf 644 <<CONF
[WebService]
Origins = https://${host} wss://${host}
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
LoginTo = false
CONF
  if [ "$MODE" != dry ]; then
    grep -qx root /etc/cockpit/disallowed-users 2>/dev/null || echo root >> /etc/cockpit/disallowed-users
    systemctl daemon-reload
    systemctl enable --now cockpit.socket >/dev/null 2>&1 || true
    systemctl restart cockpit.socket
  else
    echo "  + add root to /etc/cockpit/disallowed-users; restart cockpit.socket"
  fi
  echo "  Next (once svc:${COCKPIT_SVC} exists in iac/tailscale-services + policy):"
  echo "    sudo tailscale serve --service=svc:${COCKPIT_SVC} --https=443 127.0.0.1:${COCKPIT_PORT}"
}
verify_cockpit() {
  if [ -z "$COCKPIT_SVC" ] || [ -z "$TS_TAILNET_DNS" ]; then echo "  cockpit: skipped (COCKPIT_SVC/TS_TAILNET_DNS unset)"; return 0; fi
  installed cockpit-ws && ok "cockpit installed" || bad "cockpit missing"
  ss -tln | grep "127.0.0.1:${COCKPIT_PORT} " >/dev/null && ok "cockpit on localhost:${COCKPIT_PORT}" || bad "cockpit not listening on 127.0.0.1:${COCKPIT_PORT}"
  ss -tln | grep -E '(0\.0\.0\.0|\*|\[::\]):(9090|'"${COCKPIT_PORT}"') ' >/dev/null && bad "cockpit reachable beyond localhost" || ok "cockpit not public"
  grep -x root /etc/cockpit/disallowed-users >/dev/null 2>&1 && ok "root disallowed in cockpit" || bad "root not disallowed"
  grep "Origins = https://${COCKPIT_SVC}.${TS_TAILNET_DNS}" /etc/cockpit/cockpit.conf >/dev/null 2>&1 && ok "Origins pinned to svc:${COCKPIT_SVC}" || bad "Origins not set"
  installed network-manager && bad "NetworkManager got installed (check renderer)" || ok "no NetworkManager pulled in"
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
  tailscale status --self --json 2>/dev/null | grep "\"${TS_TAG}\"" >/dev/null && ok "tagged ${TS_TAG}" || bad "not tagged ${TS_TAG} (yet)"
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
