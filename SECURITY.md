# home0ps security design (global baseline)

Shared controls for every home0ps system. Each host role adds its own summary in [`security/`](security/) covering only what differs: exposed services, exemptions, role-specific risks.

> **Standard:** every system and service is covered by this file plus its role file (risk → control, accepted risks, open issues). Update them **in the same change** that alters the system. Goal: feed the factual parts automatically from scan results and config (kaywoz/home0ps#102).

| Role | Summary |
|---|---|
| Monitoring host (Raspberry Pi 5) | [`security/monitoring.md`](security/monitoring.md) |
| Apps host (Intel N305) | `security/apps.md` — from day one of kaywoz/home0ps#118 |
| Storage host (MOS NAS) | `security/storage.md` — later |
| Lab (XCP-ng) | `security/lab.md` — later, not home0ps production |

## Access model

Two independent planes:

- **Admin plane: Tailscale.** Admin UIs are Tailscale Services (`svc:<app>` on 443, `ts.net` certs), reachable only through explicit grants in `iac/tailscale/policy.hujson`. Tailscale is also the break-glass path.
- **User plane: Cloudflare Tunnel + Access.** User-facing apps sit behind outbound-only `cloudflared` connectors next to the apps, with Access in front.

## Network exposure

| Risk | Control |
|---|---|
| Lateral movement between systems | UniFi zone-based firewall: each network is its own zone with internet-only egress; only admin stations reach all zones |
| Services reachable from LAN/internet | Containers publish on `127.0.0.1` only; admin UIs via Tailscale Services, user apps via Cloudflare Tunnel |
| Over-broad tailnet access | Per-service and per-flow grants, tag-based identities, ACL `tests` run on every policy PR |
| Policy mistakes | Policy in git, `test` job gates every PR; merge = deploy (no approver, by choice) |

## Authentication

| Risk | Control |
|---|---|
| SSH brute force | Keys only, no root, no passwords, no forwarding |
| Access after reaching the tailnet | Every app has its own login; tailnet access alone grants nothing |
| Attacker-created accounts | Self-registration disabled in every app |

## Containment (container standard)

| Risk | Control |
|---|---|
| Container escape to root | `userns-remap` daemon-wide; exemptions only where technically required, listed per role |
| Privilege escalation, persistence | Non-root `user`, `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges` (also daemon-wide) |
| App-to-app spread | One bridge network per app; `internal: true` where possible; `icc: false` |
| Docker control via tooling | Only `docker-socket-proxy` mounts `docker.sock`, `POST=0` |
| Resource exhaustion | `mem_limit`, `pids_limit` on every container |

## Platform

| Risk | Control |
|---|---|
| Known vulnerabilities | `unattended-upgrades` with automatic reboot |
| Kernel exploitation / info leaks | `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`, `rp_filter=1` |
| Unused attack surface | Unneeded packages purged per role |

## Secrets

| Risk | Control |
|---|---|
| Leak via repository | `.env`, `*.env`, secret YAML, private keys and Terraform state are gitignored; only `*.example` templates are committed |
| Leak via files on hosts | Secret files `600`, owned by the container's (remapped) host UID |
| Exposure via `docker inspect` | Secrets as files where the app supports it |
| Exposed credentials | Rotate after any disclosure — open: kaywoz/home0ps#114 |

## Detection and integrity

| Risk | Control |
|---|---|
| Log loss / tampering | Persistent journal (capped, 30 days), Forward Secure Sealing, verification key off-host |
| Blind spots | Docker `journald` log driver: one journal covers host and containers |
| Evidence loss on compromise | Native, sandboxed Fluent Bit ships the journal off-box to LogTide with disk buffering |
| Silent sender failure | Log pipeline watchdog (kaywoz/home0ps#116) |
| Unnoticed problems | Alerts to Slack (cloud, so delivery doesn't depend on any home0ps host) — kaywoz/home0ps#115 |

## Recovery

| Risk | Control |
|---|---|
| Slow or inconsistent rebuild | Hardening scripts with `--verify`, rebuild checklists, compose and IaC in git |
| Persistence after compromise | Rebuild, never clean; restore data; rotate all secrets |

## Improbable risks

| Risk | Control |
|---|---|
| Someone utters the forbidden word (`sudo !!`) at Sunday brunch, summoning the Dogcat of Unscheduled Maintenance, which halts every container and demands a towel | The Dogcat is unionised and contractually barred from working Sundays, and only answers requests signed with a hardware key. A towel has been left lying around for it; whoever picks it up trips the alarm. (The towel is a **canary token**; its location is deliberately not recorded anywhere in git — kaywoz/home0ps#104.) |

## Accepted risks (all systems)

- One shared LogTide ingest key: senders can spoof `metadata.host`.
- Images on `:latest`: unvetted upstream changes (compensated by Diun kaywoz/home0ps#101 and Trivy kaywoz/home0ps#102).
- Some apps only take secrets as env vars (visible via `docker inspect` / the socket proxy).
- Slack sees alert text: alerts carry host/service/state only. Webhook URLs are bearer secrets.

## Open issues

- Vulnerability scanning feeding these summaries — kaywoz/home0ps#102
- Canary token — kaywoz/home0ps#104
- Rotate credentials exposed during planning — kaywoz/home0ps#114
- Automated summary upkeep: derive exposed services, exemptions and images from `compose.yaml`, `daemon.json` and the Tailscale policy, so drift is detected rather than discovered
