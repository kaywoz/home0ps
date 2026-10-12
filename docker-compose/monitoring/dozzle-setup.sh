#!/usr/bin/env bash
# One-time Dozzle setup on the monitoring host: own mTLS cert pair + first user. Run from /srv/docker.
set -euo pipefail
UIDMAP=165534   # container 65534 under userns-remap (base 100000)
mkdir -p dozzle/certs dozzle/data

if [ ! -f dozzle/certs/key.pem ]; then
  echo "== Generating Dozzle mTLS key and certificate (valid 5 years)"
  umask 077
  openssl genpkey -algorithm Ed25519 -out dozzle/certs/key.pem
  openssl req -new -x509 -key dozzle/certs/key.pem -out dozzle/certs/cert.pem \
    -days 1825 -subj "/O=krypinet/CN=dozzle-mtls"
  openssl x509 -in dozzle/certs/cert.pem -noout -subject -enddate
else
  echo "== Cert pair exists, keeping it"
fi

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
sudo chmod 700 dozzle/certs dozzle/data
sudo chmod 600 dozzle/certs/key.pem dozzle/data/users.yml
sudo chmod 644 dozzle/certs/cert.pem
for p in dozzle/data/ dozzle/certs/key.pem; do grep -qxF "$p" .gitignore 2>/dev/null || echo "$p" >> .gitignore; done
echo "== Done. Next: docker compose up -d dozzle"
