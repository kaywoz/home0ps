# Monitoring host security design

Raspberry Pi 5 (8 GB, 128 GB NVMe), Raspberry Pi OS Lite 64-bit. **Observation-only:** may read everything (metrics, logs, health), may change nothing elsewhere. Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`config-files/rpi/HARDENING.md`](../config-files/rpi/HARDENING.md) + [`harden-rpi5.sh`](../config-files/rpi/harden-rpi5.sh). Stack: [`docker-compose/monitoring/`](../docker-compose/monitoring/).

## Network exposure

| Risk | Control |
|---|---|
| Lateral movement from this host | Own zone on the monitoring VLAN, internet-only egress; access port, tagged VLANs blocked |
| Services reachable from LAN/internet | UIs only as Tailscale Services on 443 (`svc:gatus`, `svc:beszel`, `svc:dozzle`, `svc:logtide`, `svc:logtide-api`, `svc:healthchecks`, `svc:cockpit-janky`); all ports on `127.0.0.1`, Beszel agent on `172.31.250.1` (bridge gateway only) |
| Non-tailnet inbound | Only LAN syslog (UDP/TCP 514), restricted to LAN ranges, not on the Tailscale interface — kaywoz/home0ps#97 |
| Tailscale feature abuse | `tag:monitoring` only; no `--accept-routes`; stale nodes removed. Tailscale SSH on: privusers only, admin account only, 24h check, never root (`sshTests`); sshd stays on the LAN address as break-glass |
| Over-broad tailnet access | Admin grant to the `svc:*` list on 443; explicit outbound grants per flow (Beszel agent pull on 45876, Dozzle reads remote hosts' read-only socket proxies on 2375); observed hosts may push only to `svc:logtide-api`, `svc:healthchecks` and `svc:beszel` (Beszel agent WebSocket), each with an ACL test |
| Wireless / serial attack surface | Wi-Fi, Bluetooth, UART disabled (`-pi5` overlays) |

## Authentication

| Risk | Control |
|---|---|
| Access after reaching the tailnet | Gatus basic auth, Beszel + GitHub OAuth (`USER_CREATION=false`), Dozzle `simple` auth, Cockpit PAM, LogTide, Healthchecks (`REGISTRATION_OPEN=False`) |
| Cockpit as pivot | `LoginTo = false`, root disallowed, `Origins` pinned, listens on `127.0.0.1:9091` |

## Containment

| Risk | Control |
|---|---|
| `userns-remap` exemptions | Only the socket proxy (must open `docker.sock`) and the Beszel agent (host networking; runs as real UID 65534) |
| Docker control via monitoring tools | Dozzle actions off; Beszel agent and Dozzle read through the socket proxy (`POST=0`). Remote hosts also only through their own `POST=0` proxies (Dozzle remote-host mode), never Dozzle agents: an agent needs the full socket and allows exec into containers (decided 2026-11-07) |
| This host controlling others | No write paths outward (no Dockhand/Hawser here); agents are pulled over scoped grants, or push to the hub's Service; inbound pushes reach only those three Services |
| Direct DB access | LogTide Postgres/Redis on the internal `logtide-db` network, no published ports |
| Compromised log shipper | Fluent Bit as `fluentbit` (`systemd-journal`), no capabilities, `ProtectSystem=strict`, `MemoryMax` |
| Memory limits silently ignored | `cgroup_enable=memory` on the kernel cmdline (off by default on Raspberry Pi OS) |

## Platform

| Risk | Control |
|---|---|
| Known vulnerabilities | Unattended upgrades incl. Raspberry Pi Foundation origin, auto reboot 04:00 |
| Unused attack surface | Purged avahi, cups, bluez, wpasupplicant, triggerhappy |
| Boot tampering | `BOOT_ORDER=0xf6` (NVMe only) |
| Log shipper failure on 16K pages | `kernel=kernel8.img` (4K pages) |

## Secrets

| Risk | Control |
|---|---|
| Gatus secrets | `security.yaml`, `heartbeat.yaml`, `alerting.yaml` as files (`600`, owned 165534), gitignored |

## Detection

| Risk | Control |
|---|---|
| Undetected logins | sshd, PAM, sudo, tailscaled, Beszel request logs captured in LogTide |
| Silent host failure | Gatus heartbeat to Healthchecks.io (external) every 5 minutes |
| LogTide feedback loops | Fluent Bit excludes LogTide's own containers and its own unit |

## Accepted risks (this role)

- `userns-remap` exemptions: socket proxy, Beszel agent.
- LogTide and Healthchecks secrets are env vars (visible via the socket proxy).
- Dozzle → remote socket proxies is plain HTTP inside WireGuard (no TLS of its own); the ACL grant (tcp:2375, `tag:monitoring` only) is the gate, and the proxies only allow read calls. Dozzle documents remote-host mode as superseded by agents (no upstream support for its issues).
- Gatus doesn't log failed logins.

## Open issues

- Container limits drift between repo and running containers — kaywoz/home0ps#98
- UniFi gateway syslog — kaywoz/home0ps#100
- SMART health for this host's NVMe — kaywoz/home0ps#103
