#!/usr/bin/env bash
# One-time Dozzle setup on the monitoring host: first user. Run from /srv/docker.
# (No cert pair: remote hosts are read through their socket proxies, not Dozzle agents.)
set -euo pipefail
UIDMAP=165534   # container 65534 under userns-remap (base 100000)
mkdir -p dozzle/data

if [ ! -f dozzle/data/users.yml ]; then
  echo "== Creating first Dozzle user"
  read -rp  "Username [kaywoz]: " DU; DU=${DU:-kaywoz}
  read -rp  "Email: " DE
  read -rsp "Password: " DP; echo
  docker run --rm amir20/dozzle generate --name "$DU" --email "$DE" --password "$DP" "$DU" > dozzle/data/users.yml
  unset DP
else
  echo "== users.yml exists, keeping it"
fi

sudo chown -R "$UIDMAP:$UIDMAP" dozzle
sudo chmod 700 dozzle/data
sudo chmod 600 dozzle/data/users.yml
for p in dozzle/data/; do grep -qxF "$p" .gitignore 2>/dev/null || echo "$p" >> .gitignore; done
echo "== Done. Next: docker compose up -d dozzle"
