#!/usr/bin/env bash
# setup-logging.sh — persistent, sealed journald + Docker journald log driver. Logs stay on the host.
# Run from the directory holding these files:  sudo ./setup-logging.sh
# Re-runnable. Does NOT recreate containers; it tells you to.
# Off-box shipping (Fluent Bit -> LogTide) is archived: archive/config-files/log-shipping/ (kaywoz/home0ps#207).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== journald: persistent, capped, rate limits relaxed, sealing"
install -D -m 644 "$HERE/journald-50-logging.conf" /etc/systemd/journald.conf.d/50-logging.conf
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
journalctl --flush
mkdir -p /var/log/journal/"$(cat /etc/machine-id)"
if [ ! -e /var/log/journal/"$(cat /etc/machine-id)"/fss ]; then
  echo "== Forward Secure Sealing keys — STORE THE VERIFICATION KEY OFF THIS BOX:"
  journalctl --setup-keys
fi

echo "== Docker: journald log driver"
[ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
install -m 644 "$HERE/daemon.json" /etc/docker/daemon.json
systemctl restart docker

cat <<MSG

Done. Next:
  Recreate containers so they use journald:   cd /srv/docker && docker compose up -d --force-recreate
MSG
