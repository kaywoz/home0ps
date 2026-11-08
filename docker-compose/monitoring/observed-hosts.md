# Onboarding an observed host (Dozzle + Beszel)

How a host becomes visible to the monitoring host: Docker logs in Dozzle (remote-host mode through a read-only socket proxy) and metrics in Beszel. Design and reasons: kaywoz/home0ps#138, [`security/monitoring.md`](../../security/monitoring.md). Done so far: media LXC, storage host, infra VM; apps VM in progress.

Values used below — set them in the monitoring host's shell. The IP is looked up from the tailnet, so a value from an earlier host can't carry over:

```bash
H=<hostname>; IP=$(tailscale ip -4 "$H"); echo "$H -> $IP"
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

Check first whether an agent already runs natively (Beszel's install script; the infra VM and apps VM have one) — then don't add a container agent, harden the native one instead:

```bash
systemctl is-active beszel-agent; id beszel 2>/dev/null
```

Native agent (Ubuntu/Debian): harden it with [`config-files/ubuntu/beszel-agent.sh`](../../config-files/ubuntu/beszel-agent.sh) — tailnet-only `LISTEN`, Docker through the read-only proxy, out of the `docker`/`disk` groups — after the proxy is up. Otherwise, the container agent:

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

Rebuild `DOZZLE_REMOTE_HOST` from the list of **all** observed hosts (hostnames, not in git), with each IP looked up from the tailnet — rerunnable, no duplicates, no stale IPs; nothing is written if any host doesn't resolve:

```bash
cd /srv/docker && HOSTS="<host> <host> ..." TN=<tailnet>.ts.net; L=; for h in $HOSTS; do ip=$(tailscale ip -4 "$h") && [ -n "$ip" ] || { echo "no tailnet IP for $h"; L=; break; }; L="$L${L:+,}tcp://$ip:2375|$h.$TN"; done; [ -n "$L" ] && sudo sed -i "s#^DOZZLE_REMOTE_HOST=.*#DOZZLE_REMOTE_HOST=$L#" .env && grep '^DOZZLE_REMOTE_HOST=' .env && docker compose up -d dozzle
```

## Publishing an admin UI as a Tailscale Service

Not part of onboarding, but the same kind of host step:

1. PR: add the service to [`iac/tailscale-services/services.tf`](../../iac/tailscale-services/services.tf) and its grant + `autoApprovers` entry to [`iac/tailscale/policy.hujson`](../../iac/tailscale/policy.hujson). Merge **before** serving, or auto-approval doesn't trigger.
2. On the host, with the app on `127.0.0.1:<port>`:

```bash
sudo tailscale serve --service=svc:<name> --https=443 127.0.0.1:<port>
```

Check with `tailscale serve status`; the "approval from an admin is required" message is printed regardless ([`config-files/rpi/HARDENING.md`](../../config-files/rpi/HARDENING.md)).

## Speeding this up (ideas, parked)

- **Host list in `.env`:** keep the observed hostnames in a host-local variable (e.g. `DOZZLE_HOSTS`), so step 5 needs no typing at all.
- **`onboard-observed.sh`** on the host: step 2's `tailscale serve` + local `_ping`, step 3's data-folder ownership, and print the tailnet IP for the hub.
- **Tag at join:** `baseline.sh` already prints `tailscale up --advertise-tags=${TS_TAG}` (default `tag:observed`), but takes one tag; accepting a list (role tag + `tag:observed`) would skip step 1 for new hosts. Hosts not built with `baseline.sh` (MOS) still need the console.
- **Compose hosts:** keep `socketproxy` and the Beszel agent in every host's compose, so step 2–3 is `docker compose up -d`.
