#!/usr/bin/env bash
# One-time Healthchecks setup on the monitoring host. Run from /srv/docker.
set -euo pipefail
touch .env && chmod 600 .env
# A key line with no value (as copied from .env.example) counts as missing: replace it.
if ! grep '^HC_SECRET_KEY=..*' .env >/dev/null; then
  sed -i '/^HC_SECRET_KEY=[[:space:]]*$/d' .env
  echo "HC_SECRET_KEY=$(openssl rand -hex 32)" >> .env
fi
grep '^HC_SECRET_KEY=..*' .env >/dev/null || { echo "HC_SECRET_KEY still empty in .env" >&2; exit 1; }
docker compose up -d healthchecks
echo "== Waiting for Healthchecks..."; sleep 15
echo "== Healthchecks admin account (email + password):"
docker compose exec healthchecks /opt/healthchecks/manage.py createsuperuser
