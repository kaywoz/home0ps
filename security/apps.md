# Apps host security design

> **Being re-planned (kaywoz/home0ps#174):** the apps role moved from the bare-metal N305 into the **apps VM on the storage host (MOS)**. Rows below that describe the bare-metal host (switch port, Cockpit service name) are to be reviewed with #118/#174; the monitoring rows reflect the VM (2026-11-08).

Intel N305 (4× 2.5GbE, dual NVMe), **Ubuntu 26.04 LTS**. Runs **trusted, well-known apps only**, all as containers; anything risky or needing `privileged` goes to the XCP-ng lab instead. Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`config-files/ubuntu/baseline.sh`](../config-files/ubuntu/baseline.sh) then [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) — both ran clean on this host (2026-10-19). Build-out: kaywoz/home0ps#118.

**Status legend:** controls without a marker are in place and verified by the scripts' `--verify` or by observation; *(planned)* items are tracked in the linked issue.

## Network exposure

| Risk | Control |
|---|---|
| Lateral movement from this host | UniFi zone with internet-only egress; switch port VLAN 31 native + 13 tagged only, never management *(planned, #118)* |
| Containers reaching other VLAN 31 hosts (storage host) | `DOCKER-USER` rule blocking container bridges → VLAN 31 *(planned, #118)* |
| IoT-facing apps on VLAN 13 | macvlan on the VLAN 13 sub-interface, no host IP on it *(planned, #118)* — keeps the host itself off the IoT network |
| Over-broad tailnet access | `tag:docker` + `tag:observed` + `tag:ssh` (apps VM, 2026-11-08). Inbound from the tailnet: monitoring host → tcp:45876 (Beszel agent) and tcp:2375 (read-only socket proxy for Dozzle, via `tailscale serve`); infra VM → tcp:2376 (Hawser, Dockhand-home); privusers → tcp:22, 80, 443 (admin baseline grants). Outbound pushes limited to `svc:logtide-api`, `svc:healthchecks`, `svc:beszel` |
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
| Docker control via monitoring agents | Read-only socket proxy `kr-ccp-socketproxy-0501` (`POST=0`, `127.0.0.1:2375`, `tailscale serve --tcp=2375`) for Dozzle and the native Beszel agent. Agent found 2026-11-08 with `PORT=45876` (SSH fallback would listen on all interfaces; idle while its WebSocket is up), in `disk`, not in `docker`; hardened by [`beszel-agent.sh`](../config-files/ubuntu/beszel-agent.sh): tailnet-only `LISTEN`, `DOCKER_HOST` → proxy, out of `disk` *(untested)* |
| Central Docker management (Hawser) | `kr-ccp-hawser-0101` lets Dockhand-home on the infra VM manage this Docker in standard mode: **full socket**, so the token holder is ≈ root here (accepted, CLAUDE.md §8). Published on `127.0.0.1:2376` only, exposed via `tailscale serve --tcp=2376`; only `tag:infra` may reach it (policy grant + ACL tests). Token as a file (`/srv/docker/hawser/token`, 600, owned 2102, `TOKEN_FILE`), never an env var: env vars are readable through the read-only socket proxy. uid 2102 (`user:` + docker `group_add`), `read_only`, `/run/hawser` tmpfs, `cap_drop: [ALL]`, `no-new-privileges`, 256 MB / 200 pids. `userns_mode: host` to open the socket under `userns-remap`. After 10 failed tokens in a minute Hawser blocks the source address for a minute — through `tailscale serve` every caller looks the same, so that also blocks Dockhand briefly. No stacks folder (compose stays in git). Verified 2026-11-09 from the infra VM over the tailnet: `/_hawser/health` healthy, `/version` without token → 401; added in Dockhand with the token. running container checked the same day: `uid=2102`, groups docker (989) + 2102, `ReadonlyRootfs=true`, `CapDrop=[ALL]` |
| Local LLM API (Ollama) | `kr-ccp-ollama-0101` (#261): the API has **no built-in authentication** (none in docs.ollama.com/faq), so it is published on `127.0.0.1:11434` only; local consumers reach it on the `proxy-ollama` network. No Tailscale Service or Cloudflare exposure yet; a remote consumer gets a Service plus one grant with an ACL test. uid 2103 (remapped), `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, 8 GB / 3 CPUs / 512 pids; one model loaded, one request at a time, 10 min keep-alive. Consumers send only what they need (names, metadata), never secrets. Models pulled by kaywoz into `/srv/docker/ollama/models` (owned 102103). Non-root run, read-only root and healthcheck *(untested)* |
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
- Admin baseline grants give privusers tcp:22/80/443 to every device, this one included.

## Open issues

- Remaining build-out: trunk port, VLAN 13 macvlan, `DOCKER-USER` rule, cloudflared + Access, Homey / Home Assistant / Jellyfin — kaywoz/home0ps#118
- Dozzle / Beszel agent templates — kaywoz/home0ps#138
- Tailscale onboarding and tooling in `baseline.sh` — kaywoz/home0ps#154
- Vulnerability scanning feeding this file — kaywoz/home0ps#102
