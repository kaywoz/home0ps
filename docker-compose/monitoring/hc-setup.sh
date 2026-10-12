#!/usr/bin/env bash
# One-time Healthchecks setup on the monitoring host. Run from /srv/docker.
set -euo pipefail
touch .env && chmod 600 .env
grep -q '^HC_SECRET_KEY=' .env || echo "HC_SECRET_KEY=$(openssl rand -hex 32)" >> .env
docker compose up -d healthchecks
echo "== Waiting for Healthchecks..."; sleep 15
echo "== Healthchecks admin account (email + password):"
docker compose exec healthchecks /opt/healthchecks/manage.py createsuperuser
