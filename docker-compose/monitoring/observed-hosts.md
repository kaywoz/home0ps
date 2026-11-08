# Onboarding an observed host (Dozzle + Beszel)

How a host becomes visible to the monitoring host: Docker logs in Dozzle (remote-host mode through a read-only socket proxy) and metrics in Beszel. Design and reasons: kaywoz/home0ps#138, [`security/monitoring.md`](../../security/monitoring.md). Done so far: media LXC, storage host; infra VM in progress.

Values used below — set them once per shell:

```bash
IP=<host-tailnet-ip>          # tailscale ip -4 on the host
FQDN=<hostname>.<tailnet>.ts.net
```

The host's MagicDNS name, which is also its Dozzle label, can be read on the host itself:

```bash
tailscale status --self --json | grep -m1 '"DNSName"'
```

## 1. Tag (Tailscale admin console)

Add `tag:observed` to the host, keeping its role tag. Use the console, not `tailscale set` over your own Tailscale SSH session. The grants already exist: monitoring → tcp:45876 and tcp:2375, host → `svc:beszel` / `svc:healthchecks` / `svc:logtide-api`. No policy change needed.

## 2. Socket proxy on the host

Name every new container from the [container register](../CONTAINERS.md) (next free group number) and add it there in the same change.

- **Compose hosts:** the `socketproxy` service as in [`../media/compose.yaml`](../media/compose.yaml) (bridge, `127.0.0.1:2375`, `POST=0`), `docker compose up -d socketproxy`.
- **MOS:** Docker Socket Proxy template with the deploy settings in [`config-files/mos/containers.md`](../../config-files/mos/containers.md). Network bridge, never host.

Then expose it on the tailnet and check it locally, in one go (as root or with `sudo`):

```bash
tailscale serve --bg --tcp=2375 tcp://localhost:2375 && tailscale ip -4 && curl -s --max-time 5 http://127.0.0.1:2375/_ping; echo
```

## 3. Beszel agent on the host

In the hub, add the system (host `$IP`, port 45876) and copy key and token. Agent: host network, `DOCKER_HOST=tcp://127.0.0.1:2375`, `LISTEN=<tailnet-ip>:45876`, `HUB_URL=https://beszel.<tailnet>.ts.net`, runs as uid 65534.

Data folder permissions before the first start (the agent can't write its state otherwise). Under `userns-remap` without `userns_mode: host` the owner is `165534` instead:

```bash
D=<appdata>/beszel/agent; mkdir -p "$D" && chown 65534:65534 "$D" && ls -ldn "$D"
```

Check the agent connected:

```bash
docker logs --tail 10 $(docker ps -qf ancestor=henrygd/beszel-agent:latest) 2>&1
```

## 4. Tests (monitoring host)

Read OK, write refused:

```bash
curl -s --max-time 5 http://$IP:2375/_ping; echo; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 -X POST http://$IP:2375/containers/x/restart
```

Expect `OK`, then `403`. From a LAN device, the host's LAN address on 2375 must be refused. From an admin's device it times out on every host except the storage host (admins have `*` there).

## 5. Dozzle (monitoring host)

Append the host to `DOZZLE_REMOTE_HOST` (skipped if already listed; needs at least one existing entry) and recreate Dozzle:

```bash
cd /srv/docker && { grep -q "|$FQDN" .env || sudo sed -i "s#^\(DOZZLE_REMOTE_HOST=.*\)\$#\1,tcp://$IP:2375|$FQDN#" .env; } && grep '^DOZZLE_REMOTE_HOST=' .env && docker compose up -d dozzle
```

For the very first entry, set the line by hand: `DOZZLE_REMOTE_HOST=tcp://<ip>:2375|<fqdn>`.

## Publishing an admin UI as a Tailscale Service

Not part of onboarding, but the same kind of host step:

1. PR: add the service to [`iac/tailscale-services/services.tf`](../../iac/tailscale-services/services.tf) and its grant + `autoApprovers` entry to [`iac/tailscale/policy.hujson`](../../iac/tailscale/policy.hujson). Merge **before** serving, or auto-approval doesn't trigger.
2. On the host, with the app on `127.0.0.1:<port>`:

```bash
sudo tailscale serve --service=svc:<name> --https=443 127.0.0.1:<port>
```

Check with `tailscale serve status`; the "approval from an admin is required" message is printed regardless ([`config-files/rpi/HARDENING.md`](../../config-files/rpi/HARDENING.md)).

## Speeding this up (ideas, parked)

- **`dozzle-add-host.sh <ip> <fqdn>`** on the monitoring host: the step-5 one-liner as a script that also handles an empty list and validates the IP.
- **`onboard-observed.sh`** on the host: step 2's `tailscale serve` + local `_ping`, step 3's data-folder ownership, and print `IP`/`FQDN` for steps 4–5.
- **Tag at join:** `baseline.sh` already prints `tailscale up --advertise-tags=${TS_TAG}` (default `tag:observed`), but takes one tag; accepting a list (role tag + `tag:observed`) would skip step 1 for new hosts. Hosts not built with `baseline.sh` (MOS) still need the console.
- **Compose hosts:** keep `socketproxy` and the Beszel agent in every host's compose, so step 2–3 is `docker compose up -d`.
