# Apps host security design

Intel N305 (4× 2.5GbE, dual NVMe), **Ubuntu 26.04 LTS**. Runs **trusted, well-known apps only**, all as containers; anything risky or needing `privileged` goes to the XCP-ng lab instead. Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`config-files/ubuntu/baseline.sh`](../config-files/ubuntu/baseline.sh) then [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) — both ran clean on this host (2026-10-19). Build-out: kaywoz/home0ps#118.

**Status legend:** controls without a marker are in place and verified by the scripts' `--verify` or by observation; *(planned)* items are tracked in the linked issue.

## Network exposure

| Risk | Control |
|---|---|
| Lateral movement from this host | UniFi zone with internet-only egress; switch port VLAN 31 native + 13 tagged only, never management *(planned, #118)* |
| Containers reaching other VLAN 31 hosts (storage host) | `DOCKER-USER` rule blocking container bridges → VLAN 31 *(planned, #118)* |
| IoT-facing apps on VLAN 13 | macvlan on the VLAN 13 sub-interface, no host IP on it *(planned, #118)* — keeps the host itself off the IoT network |
| Over-broad tailnet access | `tag:observed` only. Inbound from the tailnet: monitoring host → tcp:45876 (Beszel agent) and tcp:7007 (Dozzle agent); privusers / trusted devices → tcp:22, 80, 443 (admin baseline grants). Outbound pushes limited to `svc:logtide-api`, `svc:healthchecks`, `svc:beszel` |
| User-facing apps exposed | Via Cloudflare Tunnel + Access (outbound-only `cloudflared`, JWT validation on), never published ports *(planned, #118)* |
| Admin UI exposure | Cockpit on `127.0.0.1:9091` only, published as `svc:cockpit-sexy`; `Origins` pinned, `LoginTo = false`, root disallowed |

## Authentication

| Risk | Control |
|---|---|
| SSH brute force | Keys only, no root, no passwords, no forwarding (`baseline.sh` `ssh`, refuses to apply without an installed key) |
| Cockpit as pivot | `LoginTo = false`, root disallowed, `Origins` pinned to the service URL |
| Beszel agent impersonation | Agent pushes with the hub's `TOKEN`; SSH fallback only accepts the hub's key |

## Containment

| Risk | Control |
|---|---|
| Container escape to root | `userns-remap` (base 100000), `no-new-privileges` daemon-wide, `icc: false`, no userland proxy, `live-restore` (`docker-host.sh` `daemon`) |
| App data ownership | Bind mounts owned by the remapped UID (container 65534 → 165534); `/srv/docker` owned by the admin user, mode 750 |
| Docker control via monitoring agents | Beszel agent should read Docker through a read-only socket proxy (`POST=0`) per §8 *(unverified on this host — check the agent's `DOCKER_HOST`)*. Dozzle agent mounts `docker.sock` directly (agents can't use a proxy) *(planned, #138)* — see accepted risks |
| Risky workloads | Not run here: anything untrusted or `privileged` goes to the lab |

## Platform

| Risk | Control |
|---|---|
| Known vulnerabilities | Unattended upgrades: Ubuntu security + updates (+ ESM), **Docker CE included**, automatic reboot 04:00, kernel/dependency cleanup |
| Snap as a second, auto-updating package channel | All snaps removed, `snapd` purged and pinned out (priority -10) |
| Kernel exploitation / info leaks | `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`, `rp_filter=1` |
| Unused attack surface | Purged avahi, cups, bluez, modemmanager, triggerhappy, popularity-contest |

## Detection

| Risk | Control |
|---|---|
| Log loss / tampering | Persistent, sealed journal; Docker `journald` driver; Fluent Bit (sandboxed, unprivileged) → `svc:logtide-api` over the tailnet with TLS and the shared ingest key (verified, real key set) |
| Silent host failure | Beszel agent visible in the hub (push over WebSocket, SSH pull as fallback) |
| Failed jobs | Heartbeat pings to `svc:healthchecks` allowed for `tag:observed` |

## Accepted risks (this role)

- Docker CE upgrades unattended: `dockerd` restarts in the 04:00 window; containers return via restart policies / `live-restore`.
- `dysk` comes from its GitHub release (checksum-verified), not apt — not covered by unattended upgrades.
- Dozzle agent (once added) holds the full Docker socket; the shared mTLS key is rotated on all hosts at once.
- Admin baseline grants give privusers / trusted devices tcp:22/80/443 to every device, this one included.

## Open issues

- Remaining build-out: trunk port, VLAN 13 macvlan, `DOCKER-USER` rule, cloudflared + Access, Homey / Home Assistant / Jellyfin — kaywoz/home0ps#118
- Dozzle / Beszel agent templates — kaywoz/home0ps#138
- Tailscale onboarding and tooling in `baseline.sh` — kaywoz/home0ps#154
- Vulnerability scanning feeding this file — kaywoz/home0ps#102
