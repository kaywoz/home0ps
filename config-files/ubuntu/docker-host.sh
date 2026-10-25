#!/bin/bash
# docker-host.sh — Docker host layer for Ubuntu hosts in home0ps. Run baseline.sh first.
#
#   sudo ./docker-host.sh                     # apply all sections, then verify
#   sudo ./docker-host.sh --dry-run           # show what would change
#   sudo ./docker-host.sh --verify            # only run the checks
#   sudo ./docker-host.sh --only docker,daemon
#   sudo ./docker-host.sh --skip logs
#   curl -fsSL https://raw.githubusercontent.com/kaywoz/home0ps/main/config-files/ubuntu/docker-host.sh | sudo bash -s -- --dry-run
#
# Sections:
#   docker  Docker CE from download.docker.com (+ nightly unattended Docker CE upgrades)
#   daemon  /etc/docker/daemon.json: userns-remap, no-new-privileges, icc off,
#           no userland proxy, live-restore, journald log driver
#   layout  /srv/docker owned by the admin user (one compose.yaml, one folder per service)
#   logs    journald + Fluent Bit -> LogTide (config-files/log-shipping/)
#
# Settings (environment, optional):
#   REPO_RAW=https://raw.githubusercontent.com/kaywoz/home0ps/main   where `logs` fetches its files
set -euo pipefail
# Command output is parsed below (apt-cache policy, sshd -T, docker info): force English.
export LC_ALL=C LANG=C

SECTIONS="docker daemon layout logs"
DOCKER_ROOT="/srv/docker"
ADMIN_USER="${SUDO_USER:-${LOCAL_UNIX_ACCOUNT:-}}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kaywoz/home0ps/main}"
LOG_FILES="setup-log-shipping.sh daemon.json fluent-bit.conf fluent-bit-override.conf journald-50-logging.conf logtide.lua logtide.env.example"

# ---- framework (same as baseline.sh) ----------------------------------------
MODE=apply; ONLY=""; SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --verify) MODE=verify ;;
    --only) ONLY="${2:?--only needs a list}"; shift ;;
    --skip) SKIP="${2:?--skip needs a list}"; shift ;;
    -h|--help) sed -n '2,22p' "$0" 2>/dev/null || true; exit 0 ;;
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

CONTAINER=$(systemd-detect-virt -c 2>/dev/null || true); [ "$CONTAINER" = none ] && CONTAINER=""

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
  if [ -z "$ONLY" ]; then return 0; fi
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}
installed() { dpkg -s "$1" >/dev/null 2>&1; }

# ---- docker: Docker CE from Docker's repository -----------------------------
apply_docker() {
  step "docker: Docker CE from download.docker.com"
  if ! installed docker-ce; then
    if [ "$MODE" = dry ]; then
      echo "  + add Docker apt repo + key, apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    else
      apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      # shellcheck disable=SC1091
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  else
    echo "  docker-ce already installed"
  fi
  run systemctl enable --now docker
  if [ -n "$ADMIN_USER" ]; then run usermod -aG docker "$ADMIN_USER"; fi
  # nightly Docker CE upgrades (kaywoz: yes on docker hosts); baseline.sh sets the reboot window
  put /etc/apt/apt.conf.d/53unattended-docker 644 <<'CONF'
// docker-host.sh (home0ps): include Docker CE in unattended upgrades.
// dockerd restarts during the window; containers return via restart policies / live-restore.
Unattended-Upgrade::Origins-Pattern {
  "origin=Docker,label=Docker CE";
};
CONF
}
verify_docker() {
  installed docker-ce && ok "docker-ce installed" || bad "docker-ce missing"
  systemctl is-active --quiet docker && ok "docker running" || bad "docker not running"
  apt-config dump 2>/dev/null | grep 'origin=Docker,label=Docker CE' >/dev/null && ok "Docker CE in unattended upgrades" || bad "Docker CE not in unattended upgrades"
}

# ---- daemon: daemon.json (identical to config-files/log-shipping/daemon.json) -
apply_daemon() {
  step "daemon: userns-remap, no-new-privileges, icc off, journald"
  # LXC mode: an unprivileged LXC already maps root to an unprivileged host user;
  # userns-remap inside it is redundant and usually fails
  local remap='  "userns-remap": "default",'
  if [ -n "$CONTAINER" ]; then remap=""; echo "  inside a container ($CONTAINER): no userns-remap (the LXC already maps root)"; fi
  { echo "{"; [ -n "$remap" ] && echo "$remap"; cat <<'CONF'
  "no-new-privileges": true,
  "icc": false,
  "userland-proxy": false,
  "live-restore": true,
  "log-driver": "journald",
  "log-opts": { "tag": "{{.Name}}" }
}
CONF
  } | put /etc/docker/daemon.json 644
  run systemctl restart docker
  echo "  Existing containers keep their old settings until recreated: docker compose up -d --force-recreate"
}
verify_daemon() {
  if [ -n "$CONTAINER" ]; then
    [ "$(awk 'NR==1{print $2}' /proc/self/uid_map)" != 0 ] && ok "unprivileged LXC (root mapped by the host)" || bad "privileged container — root is host root"
  else
    docker info 2>/dev/null | grep userns >/dev/null && ok "userns-remap active" || bad "userns-remap not active"
  fi
  [ "$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)" = journald ] && ok "log driver journald" || bad "log driver not journald"
  docker info 2>&1 | grep -i 'no memory limit support' >/dev/null && bad "memory limits unsupported (cgroup)" || ok "memory limits supported"
}

# ---- layout: /srv/docker -----------------------------------------------------
apply_layout() {
  step "layout: $DOCKER_ROOT"
  run install -d -m 750 "$DOCKER_ROOT"
  if [ -n "$ADMIN_USER" ]; then run chown "$ADMIN_USER": "$DOCKER_ROOT"; fi
  echo "  Data dirs of containers running as UID N must be owned by 100000+N (userns-remap), e.g. 65534 -> 165534"
}
verify_layout() {
  [ -d "$DOCKER_ROOT" ] && ok "$DOCKER_ROOT exists" || bad "$DOCKER_ROOT missing"
}

# ---- logs: journald + Fluent Bit -> LogTide ----------------------------------
apply_logs() {
  step "logs: journald + Fluent Bit -> LogTide"
  local here src f tmp
  here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /nonexistent)
  src="$here/../log-shipping"
  if [ ! -f "$src/setup-log-shipping.sh" ]; then   # piped via curl: fetch the files
    tmp=$(mktemp -d); src="$tmp"
    for f in $LOG_FILES; do run curl -fsSL "$REPO_RAW/config-files/log-shipping/$f" -o "$src/$f"; done
  fi
  if [ "$MODE" = dry ]; then echo "  + $src/setup-log-shipping.sh"; return 0; fi
  bash "$src/setup-log-shipping.sh"
  echo "  Then: put the shared LogTide key in /etc/fluent-bit/logtide.env (LOGTIDE_HOST=logtide-api.<tailnet>.ts.net, PORT 443, TLS On) and restart fluent-bit"
}
verify_logs() {
  grep -qs '^Storage=persistent' /etc/systemd/journald.conf.d/*.conf && ok "journal persistent" || bad "journal not persistent"
  systemctl is-active --quiet fluent-bit && ok "fluent-bit running" || bad "fluent-bit not running"
  grep -qs 'lp_REPLACE' /etc/fluent-bit/logtide.env && bad "logtide.env still has the placeholder key" || ok "logtide.env has a key"
}

# ---- main -------------------------------------------------------------------
for s in $SECTIONS; do
  if wanted "$s" && [ "$MODE" != verify ]; then "apply_$s"; fi
done
if [ "$MODE" = dry ]; then printf '\nDry run, nothing changed.\n'; exit 0; fi
step "verify"
for s in $SECTIONS; do if wanted "$s"; then "verify_$s"; fi; done
echo; [ "$FAILS" -eq 0 ] && echo "All checks passed." || { echo "$FAILS check(s) failed."; exit 1; }
