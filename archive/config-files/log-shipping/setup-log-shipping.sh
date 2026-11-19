#!/usr/bin/env bash
# setup-log-shipping.sh — journald + Docker journald driver + native, sandboxed Fluent Bit -> LogTide
# Run from the directory holding these files:  sudo ./setup-log-shipping.sh
# Re-runnable. Does NOT recreate containers; it tells you to.
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

echo "== Fluent Bit"
command -v /opt/fluent-bit/bin/fluent-bit >/dev/null || curl -fsSL https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sh
id fluentbit >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin fluentbit
install -d -m 755 /etc/fluent-bit
install -m 644 "$HERE/fluent-bit.conf" /etc/fluent-bit/fluent-bit.conf
install -m 644 "$HERE/logtide.lua"     /etc/fluent-bit/logtide.lua
if [ ! -f /etc/fluent-bit/logtide.env ]; then
  install -m 600 "$HERE/logtide.env.example" /etc/fluent-bit/logtide.env
  echo "!! Edit /etc/fluent-bit/logtide.env (API key), then: systemctl restart fluent-bit"
fi
install -D -m 644 "$HERE/fluent-bit-override.conf" /etc/systemd/system/fluent-bit.service.d/override.conf
systemctl daemon-reload
systemctl enable fluent-bit
( set -a; . /etc/fluent-bit/logtide.env; set +a; /opt/fluent-bit/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf --dry-run >/dev/null ) && echo "  config OK"
systemctl restart fluent-bit

cat <<MSG

Done. Next:
  1. Recreate containers so they use journald:   cd /srv/docker && docker compose up -d --force-recreate
  2. Check:  systemctl status fluent-bit --no-pager ; journalctl -u fluent-bit -n 30 --no-pager
MSG
