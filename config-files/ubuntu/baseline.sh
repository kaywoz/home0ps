#!/bin/bash
# baseline.sh — baseline for every Ubuntu or Debian host in home0ps. Idempotent.
# Debian: MOS guests run Debian 13 (kaywoz/home0ps#174); differences are marked "Debian:".
#
#   sudo ./baseline.sh                      # apply all sections, then verify
#   sudo ./baseline.sh --dry-run            # show what would change
#   sudo ./baseline.sh --verify             # only run the checks
#   sudo ./baseline.sh --only snap,updates  # run a subset
#   sudo ./baseline.sh --skip tailscale
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/baseline.sh | sudo bash -s -- --dry-run
#
# Sections: snap updates user ssh sysctl purge packages cockpit tailscale op
#
# Settings (environment, optional):
#   REBOOT_TIME=04:00     automatic reboot time for unattended upgrades
#   AUTO_REBOOT=true      false = never reboot automatically
#   TS_TAG=tag:observed   tag printed in the `tailscale up` hint
#   LOCAL_UNIX_ACCOUNT=   admin account when not run via sudo (e.g. as root in an LXC via lxc-attach);
#                         unset = asked on the terminal. `user` creates it (home dir, /bin/bash,
#                         sudo group) if it doesn't exist
#   TS_SSH=true           Tailscale SSH on this host (policy: privusers, admin account only,
#                         24h check, never root). false = off. sshd stays as break-glass.
#   SSH_IMPORT_ID=gh:kaywoz  ssh-import-id source for the admin user's authorized_keys
#                         (adds keys, never removes them). Empty = skip the import.
#   COCKPIT_SVC=          Tailscale Service name for this host's Cockpit: cockpit-<device>,
#                         e.g. cockpit-sexy (CLAUDE.md §4 Service-name exception). Unset: taken
#                         from an existing /etc/cockpit/cockpit.conf, else asked on the terminal
#                         (default cockpit-<hostname>, "n" skips). No terminal = section skipped.
#   TS_TAILNET_DNS=       <tailnet>.ts.net, for Cockpit's Origins. Unset: from cockpit.conf, else
#                         from Tailscale (MagicDNS suffix), else asked on the terminal.
#   COCKPIT_MODULES="cockpit-ws cockpit-system cockpit-bridge cockpit-storaged cockpit-packagekit cockpit-files cockpit-sosreport"
#   PACKAGES="htop ncdu git tealdeer|tldr unzip curl ca-certificates"
#            apt packages; "a|b" = first one installable on this release.
#            A package with no install candidate is reported, not fatal.
#   dysk is not in Ubuntu's/Debian's repos: installed from its GitHub release, checksum-verified
#
# Docker hosts: run docker-host.sh after this.
set -euo pipefail
# Command output is parsed below (apt-cache policy, sshd -T, docker info): force English.
export LC_ALL=C LANG=C

SECTIONS="snap updates user ssh sysctl purge packages cockpit tailscale op"
OP_TOKEN_CRED=/etc/home0ps/op-token.cred   # this zone's 1Password service-account token, systemd-creds sealed
OP_KEY_FPR=3FEF9748469ADBE15DA7CA80AC2D62742012EA22   # 1Password code-signing key (1Password/install-cli-action)
REBOOT_TIME="${REBOOT_TIME:-04:00}"
AUTO_REBOOT="${AUTO_REBOOT:-true}"
TS_TAG="${TS_TAG:-tag:observed}"
case "$TS_TAG" in tag:*) ;; *) TS_TAG="tag:$TS_TAG" ;; esac   # accept "media" for "tag:media"
TS_SSH="${TS_SSH:-true}"
SSH_IMPORT_ID="${SSH_IMPORT_ID-gh:kaywoz}"
PACKAGES="${PACKAGES:-htop ncdu git tealdeer|tldr unzip curl ca-certificates}"
COCKPIT_SVC="${COCKPIT_SVC:-}"
TS_TAILNET_DNS="${TS_TAILNET_DNS:-}"
COCKPIT_PORT=9091
# no cockpit-networkmanager (would pull NetworkManager onto netplan/networkd servers),
# no cockpit-pcp (not in 26.04), no machines/podman (Docker hosts, no VMs)
COCKPIT_MODULES="${COCKPIT_MODULES:-cockpit-ws cockpit-system cockpit-bridge cockpit-storaged cockpit-packagekit cockpit-files cockpit-sosreport}"
PURGE="avahi-daemon cups cups-browsed bluez modemmanager triggerhappy popularity-contest"
# sudo from a root shell (e.g. in an LXC) sets SUDO_USER=root: that is no admin account
[ "${SUDO_USER:-}" = root ] && SUDO_USER=""
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
    -h|--help) sed -n '2,34p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi
# shellcheck disable=SC1091
DISTRO=$(. /etc/os-release && echo "$ID")
case "$DISTRO" in
  ubuntu|debian) ;;
  *) echo "Not Ubuntu or Debian (see /etc/os-release)." 1>&2; exit 1 ;;
esac

# LXC mode: inside a container, kernel settings belong to the host
# Admin account: SUDO_USER, else LOCAL_UNIX_ACCOUNT, else ask on the terminal (also works when
# piped from curl, e.g. as root in an LXC). Never stored by this script.
if [ -z "$ADMIN_USER" ] && { : </dev/tty; } 2>/dev/null; then
  read -r -p "Admin account (LOCAL_UNIX_ACCOUNT): " ADMIN_USER </dev/tty || true
fi
if [ "$ADMIN_USER" = root ]; then echo "root can't be the admin account (set LOCAL_UNIX_ACCOUNT)" 1>&2; exit 1; fi
if [ -n "$ADMIN_USER" ] && ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid account name: $ADMIN_USER" 1>&2; exit 1
fi
CONTAINER=$(systemd-detect-virt -c 2>/dev/null || true); [ "$CONTAINER" = none ] && CONTAINER=""
if [ -n "$CONTAINER" ]; then echo "Running inside a container ($CONTAINER): sysctl section skipped (host's job)"; fi

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
  local origins
  if [ "$DISTRO" = debian ]; then
    # Debian: the active lines of Debian's 50unattended-upgrades, plus -updates (as on Ubuntu)
    origins='  "origin=Debian,codename=${distro_codename},label=Debian";
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  "origin=Debian,codename=${distro_codename}-updates";'
  else
    origins='  "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
  "origin=Ubuntu,archive=${distro_codename}-updates,label=Ubuntu";
  "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
  "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
  fi
  put /etc/apt/apt.conf.d/52unattended-local 644 <<CONF
// baseline.sh (home0ps): overrides 50unattended-upgrades. Docker CE: 53unattended-docker (docker-host.sh).
Unattended-Upgrade::Origins-Pattern {
${origins}
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
# ---- user: the admin account (sudo, /bin/bash) --------------------------------
apply_user() {
  step "user: admin account ${ADMIN_USER:-<unset>} (sudo, /bin/bash)"
  if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = root ]; then
    bad "no admin account: run via sudo, or set LOCAL_UNIX_ACCOUNT (e.g. as root in an LXC)"; return 0
  fi
  apt_install sudo
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    echo "  $ADMIN_USER exists"
  else
    run useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
  fi
  if ! id -nG "$ADMIN_USER" 2>/dev/null | grep -w sudo >/dev/null; then run usermod -aG sudo "$ADMIN_USER"; fi
  # sudo needs a password: typed by the operator at passwd's own prompt on the terminal; the
  # script never sees or stores it. No terminal (or dry run): print the step instead.
  if [ "$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" != P ]; then
    if [ "$MODE" != dry ] && { : </dev/tty; } 2>/dev/null; then
      echo "  $ADMIN_USER has no password yet (needed for sudo; login stays key-only)"
      passwd "$ADMIN_USER" </dev/tty >/dev/tty 2>&1 || echo "  WARN: passwd failed — run it by hand: passwd $ADMIN_USER"
    else
      echo "  Next: passwd $ADMIN_USER   (needed for sudo; login stays key-only)"
    fi
  fi
}
verify_user() {
  if [ -z "$ADMIN_USER" ] || ! id "$ADMIN_USER" >/dev/null 2>&1; then bad "admin account ${ADMIN_USER:-<unset>} missing"; return 0; fi
  [ "$(getent passwd "$ADMIN_USER" | cut -d: -f7)" = /bin/bash ] && ok "$ADMIN_USER shell /bin/bash" || bad "$ADMIN_USER shell is not /bin/bash"
  id -nG "$ADMIN_USER" | grep -w sudo >/dev/null && ok "$ADMIN_USER in sudo group" || bad "$ADMIN_USER not in sudo group"
  [ "$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" = P ] && ok "$ADMIN_USER has a password (sudo)" || bad "$ADMIN_USER has no password yet: passwd $ADMIN_USER"
}

apply_ssh() {
  step "ssh: keys only, no root, no forwarding"
  # LXCs get no sshd: access is Tailscale SSH, break-glass is lxc-attach on the homenas
  if [ -n "$CONTAINER" ]; then echo "  skipped: container ($CONTAINER), no sshd (Tailscale SSH + lxc-attach)"; return 0; fi
  if ! command -v sshd >/dev/null 2>&1; then echo "  skipped: no SSH server installed"; return 0; fi
  local home keys
  home=$(getent passwd "${ADMIN_USER:-root}" | cut -d: -f6)
  keys="${home:-/nonexistent}/.ssh/authorized_keys"
  # admin user's keys from GitHub; root is skipped (no root login anyway)
  if [ -n "$SSH_IMPORT_ID" ] && [ -n "$ADMIN_USER" ] && [ -n "$home" ]; then
    apt_install ssh-import-id
    run install -d -m 700 -o "$ADMIN_USER" -g "$(id -gn "$ADMIN_USER")" "$home/.ssh"
    run runuser -u "$ADMIN_USER" -- ssh-import-id -o "$keys" "$SSH_IMPORT_ID" || echo "  WARN: ssh-import-id $SSH_IMPORT_ID failed (no network?) — checking for an existing key"
  fi
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
  if [ -n "$CONTAINER" ]; then
    command -v sshd >/dev/null 2>&1 && bad "sshd installed in a container: apt purge openssh-server" || ok "no sshd (container)"
    return 0
  fi
  if ! command -v sshd >/dev/null 2>&1; then echo "  ssh: skipped (no SSH server)"; return 0; fi
  sshd -T 2>/dev/null | grep -x 'permitrootlogin no' >/dev/null && ok "SSH root login off" || bad "PermitRootLogin"
  sshd -T 2>/dev/null | grep -x 'passwordauthentication no' >/dev/null && ok "SSH passwords off" || bad "PasswordAuthentication"
}

# ---- sysctl: kernel hardening -----------------------------------------------
apply_sysctl() {
  step "sysctl: kernel hardening"
  if [ -n "$CONTAINER" ]; then echo "  skipped: inside a container ($CONTAINER) — set on the host"; return 0; fi
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
  if [ -n "$CONTAINER" ]; then echo "  sysctl: skipped (container)"; return 0; fi
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
  if installed tealdeer && [ -n "$ADMIN_USER" ] && command -v sudo >/dev/null 2>&1 && [ "$MODE" != dry ]; then
    sudo -u "$ADMIN_USER" -H tldr --update >/dev/null 2>&1 && echo "  tldr pages downloaded for $ADMIN_USER" || echo "  WARN: tldr --update failed (run it as $ADMIN_USER)"
  fi
}
# dysk (disk usage overview) isn't packaged for Ubuntu/Debian: latest GitHub release, static musl
# binary, SHA-256 from the GitHub API checked before extracting. Installed once; re-run
# with the binary removed to upgrade (not covered by unattended upgrades).
# The asset is picked by name: since v3.8.2 each target is its own dysk-<tag>-<arch>.tar.gz
# (older releases: one dysk_<ver>.zip with <arch>/dysk inside, still handled).
install_dysk() {
  if command -v dysk >/dev/null 2>&1; then echo "  dysk already installed ($(dysk --version 2>/dev/null | head -1))"; return 0; fi
  local arch meta tag url sha tmp
  case "$(uname -m)" in
    x86_64) arch=x86_64-unknown-linux-musl ;;
    aarch64|arm64) arch=aarch64-unknown-linux-musl ;;
    *) echo "  dysk: no build for $(uname -m), skipped"; return 0 ;;
  esac
  if [ "$MODE" = dry ]; then echo "  + download latest dysk release, verify sha256, install $arch/dysk -> /usr/local/bin/dysk"; return 0; fi
  # Debian: minimal images (LXC) have no python3, which parses the release JSON
  command -v python3 >/dev/null 2>&1 || apt_install python3
  meta=$(curl -fsSL https://api.github.com/repos/Canop/dysk/releases/latest)
  read -r tag url sha < <(printf '%s' "$meta" | ARCH="$arch" python3 -c '
import json, os, sys
d = json.load(sys.stdin); t = d["tag_name"]; v = t.lstrip("v"); arch = os.environ["ARCH"]
want = [f"dysk-{t}-{arch}.tar.gz", f"dysk_{v}.zip"]
a = next((a for n in want for a in d["assets"] if a["name"] == n), None)
print(t, a["browser_download_url"] if a else "-", (a.get("digest") or "").replace("sha256:", "") if a else "")')
  if [ "$url" = - ]; then bad "dysk $tag: no $arch asset in the release, not installing"; return 0; fi
  if [ -z "$sha" ]; then bad "dysk $tag: no checksum published, not installing"; return 0; fi
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/asset"
  if ! echo "$sha  $tmp/asset" | sha256sum -c --quiet -; then bad "dysk $tag: checksum mismatch, not installing"; rm -rf "$tmp"; return 0; fi
  case "$url" in
    *.tar.gz) tar -xzf "$tmp/asset" -C "$tmp" --strip-components=1 "dysk-${tag}-${arch}/dysk" ;;
    *.zip)    unzip -q -j "$tmp/asset" "$arch/dysk" -d "$tmp" ;;
  esac
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
    echo "  skipped: set COCKPIT_SVC=cockpit-<device> and TS_TAILNET_DNS=<tailnet>.ts.net"
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

# ---- tailscale: install; joining is interactive, Tailscale SSH once joined ----
ts_running() { tailscale status --json 2>/dev/null | grep '"BackendState": "Running"' >/dev/null; }
apply_tailscale() {
  step "tailscale: install (login is interactive), Tailscale SSH ${TS_SSH}"
  if command -v tailscale >/dev/null 2>&1; then
    echo "  already installed"
  elif [ "$MODE" = dry ]; then
    echo "  + curl -fsSL https://tailscale.com/install.sh | sh"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  # Tailscale SSH takes over port 22 on the tailnet address; sshd stays reachable on the LAN address.
  # tailscale refuses (no change) when this shell itself came in over the tailnet: switching would
  # drop the session mid-run, so that case only prints the step to run last.
  if command -v tailscale >/dev/null 2>&1 && ts_running; then
    run tailscale set --ssh="${TS_SSH}" \
      || echo "  WARN: not switched (session over Tailscale). Run last, then reconnect: sudo tailscale set --ssh=${TS_SSH} --accept-risk=lose-ssh"
  else
    echo "  Next: sudo tailscale up --advertise-tags=${TS_TAG} --ssh=${TS_SSH}   (no --accept-routes)"
  fi
}
verify_tailscale() {
  command -v tailscale >/dev/null 2>&1 && ok "tailscale installed" || { bad "tailscale missing"; return 0; }
  tailscale status --self --json 2>/dev/null | grep "\"${TS_TAG}\"" >/dev/null && ok "tagged ${TS_TAG}" || bad "not tagged ${TS_TAG} (yet)"
  tailscale debug prefs 2>/dev/null | grep "\"RunSSH\": ${TS_SSH}" >/dev/null && ok "Tailscale SSH ${TS_SSH}" || bad "Tailscale SSH not ${TS_SSH}"
}

# ---- op: 1Password CLI (signature-checked) + this zone's service-account token ---------------------
# How 1Password's own GitHub action installs it (1Password/install-cli-action, linux.ts + linux-signature.ts):
# version from app-updates.agilebits.com, zip from cache.agilebits.com with op + op.sig, GPG-verified
# against the pinned key below. The token (vault home0ps or lab, read-only; kaywoz/home0ps#421) is asked
# once, hidden, and sealed with systemd-creds when the host has a TPM 2.0. Without one (most VMs) it isn't
# stored unless you confirm; scripts then ask for it per setup run. Enter at the prompt skips the token.
op_key() { cat <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
P4I7jHwe0BN3iNAG1nKbGg==
=+LeX
-----END PGP PUBLIC KEY BLOCK-----
KEY
}
apply_op() {
  step "op: 1Password CLI + service-account token ($OP_TOKEN_CRED)"
  if type -P op >/dev/null; then echo "  op installed ($(op --version 2>/dev/null))"
  elif [ "$MODE" = dry ]; then echo "  + download op (latest), verify op.sig against $OP_KEY_FPR, install /usr/local/bin/op"
  else
    local v arch t g
    v=$(curl -fsSL -m 30 https://app-updates.agilebits.com/latest | python3 -c 'import sys,json;print(json.load(sys.stdin)["CLI2"]["release"]["version"])' 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { bad "op: no valid version from app-updates.agilebits.com ($v)"; return 0; }
    arch=$(dpkg --print-architecture); case "$arch" in amd64|arm64) ;; *) bad "op: unsupported architecture $arch"; return 0 ;; esac
    t=$(mktemp -d); g=$(mktemp -d)
    curl -fsSL -m 120 -o "$t/op.zip" "https://cache.agilebits.com/dist/1P/op2/pkg/v$v/op_linux_${arch}_v$v.zip" && [ -s "$t/op.zip" ] \
      || { rm -rf "$t" "$g"; bad "op: download failed"; return 0; }
    python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);[z.extract(n,sys.argv[2]) for n in ("op","op.sig")]' "$t/op.zip" "$t" \
      || { rm -rf "$t" "$g"; bad "op: zip has no op/op.sig"; return 0; }
    op_key | gpg --homedir "$g" --batch --no-tty --import 2>/dev/null
    if gpg --homedir "$g" --batch --list-keys --with-colons 2>/dev/null | grep "^fpr:*$OP_KEY_FPR:" >/dev/null \
       && gpg --homedir "$g" --batch --no-tty --verify "$t/op.sig" "$t/op" 2>/dev/null; then
      install -m 755 "$t/op" /usr/local/bin/op; echo "  op $v installed (signature verified, key $OP_KEY_FPR)"
    else bad "op: signature check failed; not installed"; fi
    rm -rf "$t" "$g"
  fi
  if [ -f "$OP_TOKEN_CRED" ]; then echo "  token present (kept)"; return 0; fi
  # Without a TPM the seal's key sits on the same disk: a copied disk or VM snapshot opens it. Default: don't
  # store; kopia-backup.sh asks the token per setup run instead (scripts read 1Password at setup only).
  local tpm=0; systemd-creds has-tpm2 >/dev/null 2>&1 && tpm=1
  if [ "$tpm" = 0 ] && [ "$MODE" != dry ] && { : </dev/tty; } 2>/dev/null; then
    local a=""
    read -r -p "  No TPM 2.0: store the token sealed with the host key only? [y/N]: " a </dev/tty || true
    [[ "$a" =~ ^[Yy] ]] || { echo "  token not stored: scripts ask for it per setup run"; return 0; }
  fi
  if [ "$MODE" = dry ]; then echo "  + ask the service-account token (hidden), seal it to $OP_TOKEN_CRED"; return 0; fi
  if ! { : </dev/tty; } 2>/dev/null; then echo "  no terminal: token not stored (run --only op in a terminal)"; return 0; fi
  local tok=""
  read -rs -p "  1Password service-account token for this zone (hidden; Enter skips): " tok </dev/tty || true; echo
  [ -n "$tok" ] || { echo "  skipped: no token"; return 0; }
  install -d -m 700 "$(dirname "$OP_TOKEN_CRED")"
  printf '%s' "$tok" | systemd-creds encrypt --name=op-token - "$OP_TOKEN_CRED"; unset tok
  chmod 600 "$OP_TOKEN_CRED"; echo "  token sealed to $OP_TOKEN_CRED ($(systemd-creds has-tpm2 >/dev/null 2>&1 && echo 'TPM 2.0 + host key' || echo 'host key only: no TPM 2.0'))"
}
verify_op() {
  type -P op >/dev/null && ok "op installed ($(op --version 2>/dev/null))" || { bad "op not installed"; return 0; }
  if [ ! -f "$OP_TOKEN_CRED" ]; then echo "  op: no service-account token (optional; baseline.sh --only op)"; return 0; fi
  [ "$(stat -c %a "$OP_TOKEN_CRED")" = 600 ] && ok "token file 600" || bad "token file not 600"
  local tok; tok=$(systemd-creds decrypt --name=op-token "$OP_TOKEN_CRED" - 2>/dev/null || true)
  [ -n "$tok" ] && ok "token unseals on this host" || { bad "token doesn't unseal"; return 0; }
  OP_SERVICE_ACCOUNT_TOKEN="$tok" op whoami >/dev/null 2>&1 && ok "token accepted by 1Password" || bad "token rejected (or 1Password unreachable)"
  unset tok
}

# ---- cockpit settings: env, else the existing config, else ask (once, before any step runs) ----
cockpit_resolve() {
  local conf=/etc/cockpit/cockpit.conf have svc dns ans def
  have=""
  if [ -f "$conf" ]; then have=$(sed -n 's#^Origins = https://\([a-z0-9-]*\)\.\([a-z0-9.-]*\) .*#\1 \2#p' "$conf" | head -1 || true); fi
  svc=${have% *}; dns=${have#* }
  [ -n "$COCKPIT_SVC" ] || COCKPIT_SVC=$svc
  [ -n "$TS_TAILNET_DNS" ] || TS_TAILNET_DNS=$dns
  if [ -z "$TS_TAILNET_DNS" ] && command -v tailscale >/dev/null 2>&1; then
    TS_TAILNET_DNS=$(tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null || true)
  fi
  # Prompts only when applying from a terminal; --verify checks what is configured.
  if [ "$MODE" != verify ] && { : </dev/tty; } 2>/dev/null; then
    if [ -z "$COCKPIT_SVC" ]; then
      def="cockpit-$(hostname -s)"
      read -r -p "Cockpit Tailscale Service name [$def] (n = no Cockpit): " ans </dev/tty || true
      case "$ans" in n|N|no) COCKPIT_SVC="" ; return 0 ;; "") COCKPIT_SVC=$def ;; *) COCKPIT_SVC=$ans ;; esac
    fi
    if [ -n "$COCKPIT_SVC" ] && [ -z "$TS_TAILNET_DNS" ]; then
      read -r -p "Tailnet DNS name (<tailnet>.ts.net): " TS_TAILNET_DNS </dev/tty || true
    fi
  fi
  case "$COCKPIT_SVC" in svc:*) COCKPIT_SVC=${COCKPIT_SVC#svc:} ;; esac
  if [ -n "$COCKPIT_SVC" ] && ! [[ "$COCKPIT_SVC" =~ ^cockpit-[a-z0-9-]+$ ]]; then
    echo "Invalid Cockpit Service name: $COCKPIT_SVC (expected cockpit-<device>)" 1>&2; exit 1
  fi
  if [ -n "$TS_TAILNET_DNS" ] && ! [[ "$TS_TAILNET_DNS" =~ ^[a-z0-9-]+\.ts\.net$ ]]; then
    echo "Invalid tailnet DNS name: $TS_TAILNET_DNS (expected <tailnet>.ts.net)" 1>&2; exit 1
  fi
  if [ -n "$COCKPIT_SVC" ] && [ -n "$TS_TAILNET_DNS" ]; then echo "Cockpit: svc:${COCKPIT_SVC} at ${COCKPIT_SVC}.${TS_TAILNET_DNS}"; fi
}
if wanted cockpit; then cockpit_resolve; fi

# ---- main -------------------------------------------------------------------
for s in $SECTIONS; do
  wanted "$s" || continue
  if [ "$MODE" != verify ]; then "apply_$s"; fi
done
if [ "$MODE" = dry ]; then printf '\nDry run, nothing changed.\n'; exit 0; fi
step "verify"
for s in $SECTIONS; do if wanted "$s"; then "verify_$s"; fi; done
echo; [ "$FAILS" -eq 0 ] && echo "All checks passed." || { echo "$FAILS check(s) failed."; exit 1; }
