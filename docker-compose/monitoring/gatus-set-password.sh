#!/usr/bin/env bash
# Writes gatus/config/security.yaml with a bcrypt+base64 password. Run from /srv/docker.
set -euo pipefail
command -v htpasswd >/dev/null || sudo apt-get install -y apache2-utils
read -rp  "Gatus username [kaywoz]: " GU; GU=${GU:-kaywoz}
read -rsp "Gatus password: " GPW; echo
read -rsp "Repeat password: " GPW2; echo
[ "$GPW" = "$GPW2" ] || { echo "Passwords don't match." >&2; exit 1; }
HASH=$(htpasswd -bnBC 10 "" "$GPW" | tr -d ':\n' | sed 's/\$2y/\$2a/' | base64 -w0)
unset GPW GPW2
umask 077
cat > gatus/config/security.yaml <<YAML
security:
  basic:
    username: "${GU}"
    password-bcrypt-base64: "${HASH}"
YAML
sudo chown 165534:165534 gatus/config/security.yaml
sudo chmod 600 gatus/config/security.yaml
grep -qxF "gatus/config/security.yaml" .gitignore 2>/dev/null || echo "gatus/config/security.yaml" >> .gitignore
docker compose restart gatus
echo "Done. Unauthenticated request returns: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/api/v1/endpoints/statuses)"
