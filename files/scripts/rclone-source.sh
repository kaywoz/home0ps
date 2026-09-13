#!/bin/bash
# rclone archive/backup script
#
# RCLONE UPLOAD CRON TAB SCRIPT
# Type crontab -e and add line below (without # )
# * * * * * root /opt/scripts/rclone.sh >/dev/null 2>&1

set -uo pipefail

LOGFILE="/var/log/rclone.log"
CONFIG="/opt/scripts/rclone/rclone.conf"

# TODO: the healthchecks.io ping URL below is still the literal "placeholder"
# path -- swap in the real check UUID(s) before relying on these pings
JOBS=(
  "/srv/dev-disk-by-uuid-cef55e21-adc6-45e4-89c2-26968aeb0d80/shares/archive/|hetznercrypt:/archive|https://hc-ping.com/placeholder"
  "/srv/dev-disk-by-uuid-cef55e21-adc6-45e4-89c2-26968aeb0d80/shares/backups/|hetznercrypt:/backups|https://hc-ping.com/placeholder"
)

for job in "${JOBS[@]}"; do
  IFS="|" read -r FROM TO PING <<< "$job"

  # a failed ping should never block the actual backup
  curl -fsS "${PING}/start" || true

  rclone --config="$CONFIG" sync "$FROM" "$TO" -P --fast-list --transfers 4 --checkers=8 \
    --order-by size,mixed,75 --max-backlog 10000 --sftp-chunk-size 32k \
    --log-file="$LOGFILE" --log-level DEBUG

  curl -fsS "$PING" || true
done
