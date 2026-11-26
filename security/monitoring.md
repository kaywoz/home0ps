# Monitoring host security design

Intel N305 (8 cores, 64 GB, 1 TB NVMe, 4× 2.5GbE), **Ubuntu 26.04 LTS**, rebuilt for this role with `baseline.sh` (kaywoz, 2026-11-26; earlier on a Raspberry Pi 5, retired). **Observation-only:** may read everything (metrics, logs, health), may change nothing elsewhere. Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`config-files/ubuntu/baseline.sh`](../config-files/ubuntu/baseline.sh), [`docker-host.sh`](../config-files/ubuntu/docker-host.sh), then [`monitoring-stack.sh`](../config-files/ubuntu/monitoring-stack.sh) (stack files, `.env`, start, `--serve`, `--verify`). The Pi build is archived in [`archive/config-files/rpi/`](../archive/config-files/rpi/). Stack: [`docker-compose/monitoring/`](../docker-compose/monitoring/).

## Network exposure

| Risk | Control |
|---|---|
| Lateral movement from this host | Own zone on the monitoring VLAN, internet-only egress; access port, tagged VLANs blocked |
| Services reachable from LAN/internet | UIs only as Tailscale Services on 443 (`svc:gatus`, `svc:beszel`, `svc:dozzle`, `svc:healthchecks`, `svc:cockpit-sexy`); all ports on `127.0.0.1`, Beszel agent on `172.31.250.1` (bridge gateway only) |
| Non-tailnet inbound | Only LAN syslog (UDP/TCP 514), restricted to LAN ranges, not on the Tailscale interface — kaywoz/home0ps#97 (blocked while LogTide is benched, #207) |
| Tailscale feature abuse | `tag:monitoring` and `tag:cockpit` only (no `tag:observed`); no `--accept-routes`; stale nodes removed. Tailscale SSH on: privusers only, admin account only, 24h check, never root (`sshTests`); sshd stays on the LAN address as break-glass |
| Over-broad tailnet access | Admin grant to the `svc:*` list on 443; explicit outbound grants per flow (Beszel agent pull on 45876, Dozzle reads remote hosts' read-only socket proxies on 2375); observed hosts may push only to `svc:healthchecks` and `svc:beszel` (Beszel agent WebSocket), each with an ACL test. One write flow out: its own backup to `svc:kopia` on 443 (append-only by Kopia ACL) |

## Authentication

| Risk | Control |
|---|---|
| Access after reaching the tailnet | Gatus basic auth, Beszel + GitHub OAuth (`USER_CREATION=false`), Dozzle `simple` auth, Cockpit PAM, Healthchecks (`REGISTRATION_OPEN=False`) |
| Cockpit as pivot | `LoginTo = false`, root disallowed, `Origins` pinned, listens on `127.0.0.1:9091` |

## Containment

| Risk | Control |
|---|---|
| `userns-remap` exemptions | Only the socket proxy (must open `docker.sock`) and the Beszel agent (host networking; runs as real UID 65534) |
| Docker control via monitoring tools | Dozzle actions off; Beszel agent and Dozzle read through the socket proxy (`POST=0`). Remote hosts also only through their own `POST=0` proxies (Dozzle remote-host mode), never Dozzle agents: an agent needs the full socket and allows exec into containers (decided 2026-11-07) |
| This host controlling others | No write paths outward (no Dockhand/Hawser here); agents are pulled over scoped grants, or push to the hub's Service; inbound pushes reach only those two Services |
| Memory limits silently ignored | cgroup v2 with the memory controller (Ubuntu default; check: `memory` in `/sys/fs/cgroup/cgroup.controllers`) |

## Platform

| Risk | Control |
|---|---|
| Known vulnerabilities | Unattended upgrades: Ubuntu security + updates (+ ESM), Docker CE included (`docker-host.sh`), automatic reboot 04:00 |
| Snap as a second, auto-updating package channel | All snaps removed, `snapd` purged and pinned out |
| Kernel exploitation / info leaks | `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`, `rp_filter=1` |
| Unused attack surface | Purged avahi, cups, bluez, modemmanager, triggerhappy, popularity-contest |

## Secrets

| Risk | Control |
|---|---|
| Gatus secrets | `security.yaml`, `heartbeat.yaml`, `alerting.yaml` as files (`600`, owned 165534), gitignored |

## Detection

| Risk | Control |
|---|---|
| Undetected logins | sshd, PAM, sudo, tailscaled, Beszel request logs in the local, sealed journal (no off-box copy while LogTide is benched, kaywoz/home0ps#207) |
| Silent host failure | Gatus heartbeat to Healthchecks.io (external) every 5 minutes |

## Accepted risks (this role)

- `svc:cockpit-sexy` is auto-approved for any `tag:cockpit` host, so another host with that tag could claim this name (kaywoz, 2026-11-26, one admin; Cockpit's own login and pinned Origins still apply).
- `userns-remap` exemptions: socket proxy, Beszel agent.
- Healthchecks secrets are env vars (visible via the socket proxy).
- Dozzle → remote socket proxies is plain HTTP inside WireGuard (no TLS of its own); the ACL grant (tcp:2375, `tag:monitoring` only) is the gate, and the proxies only allow read calls. Dozzle documents remote-host mode as superseded by agents (no upstream support for its issues).
- Gatus doesn't log failed logins.

## Open issues

- SMART health for this host's NVMe — kaywoz/home0ps#103
