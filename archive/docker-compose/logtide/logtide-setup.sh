#!/usr/bin/env bash
# One-time LogTide secrets for the monitoring host. Run from /srv/docker. Appends to .env only if missing.
set -euo pipefail
touch .env && chmod 600 .env
add() { grep -q "^$1=" .env || echo "$1=$2" >> .env; }
add LOGTIDE_DB_NAME logtide
add LOGTIDE_DB_USER logtide
add LOGTIDE_DB_PASSWORD "$(openssl rand -hex 24)"
add LOGTIDE_REDIS_PASSWORD "$(openssl rand -hex 24)"
add LOGTIDE_API_KEY_SECRET "$(openssl rand -hex 32)"   # 64 chars (>= 32 required)
grep -qxF ".env" .gitignore 2>/dev/null || echo ".env" >> .gitignore
echo "LogTide secrets present in .env:"; grep -o '^LOGTIDE_[A-Z_]*' .env
