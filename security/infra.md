# Infra VM security design

VM on the storage host (MOS), **Ubuntu**, own NIC by PCI passthrough on **VLAN 24 (infra)**. **Tier 0:** runs Dockhand-home (central Docker management for home) and, later, the home cloudflared tunnel (CLAUDE.md §8, kaywoz/home0ps#174). Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`baseline.sh`](../config-files/ubuntu/baseline.sh) then [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) (both passed `--verify`); stack: [`docker-compose/infra/`](../docker-compose/infra/compose.yaml).

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Network exposure

| Risk | Control |
|---|---|
| Over-broad tailnet access | `tag:infra` + `tag:observed` + `tag:ssh`; serves `svc:dockhand` (admins only). Outbound: tcp:2376 to the Hawser agents on the apps VM and media LXC only (the policy grant still includes the storage host: to be removed) (ACL-tested: not the monitoring host, not the lab). Inbound: monitoring host → tcp:45876 (Beszel agent) and tcp:2375 (read-only socket proxy, Dozzle); privusers are denied 2375 (ACL test) |
| Docker API exposure | `docker-socket-proxy` (`CONTAINERS`, `INFO`, `EVENTS`; `POST=0`) on bridge, `127.0.0.1:2375` only, exposed via `tailscale serve --tcp=2375` *(untested)* |
| Beszel agent | Native binary + systemd service from Beszel's install script (not a container), pushing to `svc:beszel`. Found 2026-11-08: listening on `*:45876` (LAN too), user `beszel` in `disk` (raw block devices), not in `docker` (no Docker stats). Hardened by [`beszel-agent.sh`](../config-files/ubuntu/beszel-agent.sh): drop-in with `LISTEN=<tailnet-ip>:45876` and `DOCKER_HOST` → the read-only proxy, `beszel` out of `docker` and (on VMs) `disk` *(untested)* |

## Containment

| Risk | Control |
|---|---|
| Container escape | `userns-remap` daemon-wide (`docker-host.sh`); exemption: socket proxy (opens `docker.sock`) |
| Monitoring tools controlling Docker | Dozzle and the native Beszel agent only through the read-only proxy (`POST=0`); `beszel-agent.sh --verify` fails if `beszel` is in the `docker` group |

## Dockhand-home (kaywoz/home0ps#174)

| Risk | Control |
|---|---|
| Dockhand compromise = Docker root on three hosts | Tier 0 by design (CLAUDE.md §8): its own VM through the **full Docker socket** — the one exception to the socket-proxy rule, since a write-enabled proxy adds no real protection for a management tool (`POST` + container create already allows a privileged container with host user namespace); the apps VM and media LXC through **Hawser** (standard mode, token, tcp:2376 over the tailnet). Not the storage host (kaywoz, 2026-11-09), never the monitoring host, never the lab. Environments in Dockhand (2026-11-09): this VM as **Unix Socket** (no TCP API exposed), the apps VM and media LXC as **Hawser Standard** over the tailnet |
| UI exposure | `127.0.0.1:3000` only, served as `svc:dockhand`, grant to admins only; `ORIGIN` pinned to the service URL (served 2026-11-09) |
| Unauthenticated access | Dockhand ships with **auth off**: enabled right after the first start (local admin + passkey; OIDC parked until a provider exists). Enabled 2026-11-09; the startup warning about disabled auth is gone |
| Container hardening | Runs as uid 2101 from the start (`user:`, the entrypoint's non-root mode), socket via the docker group (`group_add`), `cap_drop: [ALL]` with no capabilities added, `no-new-privileges`, 1 GB / 512 pids. No `read_only` (not documented upstream). `PUID`/`PGID` isn't used: its user setup failed under `cap_drop` and crash-looped (2026-11-09). Verified 2026-11-09: `id` → uid 2101, groups docker + 2101; UI answers 200 |
| Exec into containers | Available on all managed hosts (full socket / Hawser); only Enterprise RBAC could restrict it — accepted |
| Stored credentials | Hawser tokens, Git credentials encrypted with `$DATA_DIR/.encryption_key`; back up `dockhand/data` (losing the key = re-entering all tokens) |
| Missing audit trail | Audit log is Enterprise-only: activity log + journald (Docker `journald` driver) instead — accepted |

## Accepted risks (this role)

- Tier 0 on a VM hosted by the storage host: whoever controls the storage host controls this VM.
- Dockhand holds Docker root on the infra VM, apps VM and media LXC.
- Dockhand is BSL-licensed (free for homelab use); images on `:latest`.

## Open issues

- Dockhand-home and cloudflared — kaywoz/home0ps#174
- `DOCKER-USER` rule inside the VM — kaywoz/home0ps#118
- Host firewall — kaywoz/home0ps#219
