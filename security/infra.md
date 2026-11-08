# Infra VM security design

VM on the storage host (MOS), **Ubuntu**, own NIC by PCI passthrough on **VLAN 24 (infra)**. **Tier 0:** will run Dockhand-home (central Docker management for home) and the home cloudflared tunnel (CLAUDE.md §8, kaywoz/home0ps#174). Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`baseline.sh`](../config-files/ubuntu/baseline.sh) then [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) (both passed `--verify`); stack: [`docker-compose/infra/`](../docker-compose/infra/compose.yaml).

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Network exposure

| Risk | Control |
|---|---|
| Over-broad tailnet access | `tag:infra` + `tag:observed` + `tag:ssh`; nothing served yet. Inbound: monitoring host → tcp:45876 (Beszel agent) and tcp:2375 (read-only socket proxy, Dozzle); privusers are denied 2375 (ACL test) |
| Docker API exposure | `docker-socket-proxy` (`CONTAINERS`, `INFO`, `EVENTS`; `POST=0`) on bridge, `127.0.0.1:2375` only, exposed via `tailscale serve --tcp=2375`; from the monitoring host read OK, write `POST`→403 (2026-11-08); LAN refusal *(untested)* |
| Beszel agent | Native binary + systemd service from Beszel's install script (not a container), pushing to `svc:beszel`. Found 2026-11-08: listening on `*:45876` (LAN too), user `beszel` in `disk` (raw block devices), not in `docker` (no Docker stats). Hardened by [`beszel-agent.sh`](../config-files/ubuntu/beszel-agent.sh): drop-in with `LISTEN=<tailnet-ip>:45876` and `DOCKER_HOST` → the read-only proxy, `beszel` out of `docker` and (on VMs) `disk` — `--verify` passed 2026-11-08; idle listener while connected, Docker stats via the proxy |

## Containment

| Risk | Control |
|---|---|
| Container escape | `userns-remap` daemon-wide (`docker-host.sh`); exemption: socket proxy (opens `docker.sock`) |
| Monitoring tools controlling Docker | Dozzle and the native Beszel agent only through the read-only proxy (`POST=0`); `beszel-agent.sh --verify` fails if `beszel` is in the `docker` group |

## Planned: Dockhand-home (kaywoz/home0ps#174)

Decided 2026-11-08, details in its PR:
- Its own VM through the **full Docker socket** — the one exception to "only the socket proxy mounts `docker.sock`" (kaywoz, 2026-11-08): this is where write access to Docker is consolidated, and a write-enabled proxy would add no real protection (`POST` + container create already allows a privileged container with host user namespace, i.e. root on the VM).
- Storage host and apps VM through **Hawser, standard mode** (agent listens with a token on the tailnet IP, one grant `tag:infra` → those hosts tcp:2376). Hawser needs the full Docker socket: Dockhand ≈ root on those hosts (accepted, §8).
- Terminal/exec into containers is therefore available on all managed hosts; the controls are around Dockhand: UI only as `svc:dockhand` for admins, auth on before serving, Hawser tokens on tailnet IPs, one grant per flow.
- UI only as `svc:dockhand`, auth enabled before serving (it ships with auth off), admins only.

## Accepted risks (this role)

- Tier 0 on a VM hosted by the storage host: whoever controls the storage host controls this VM.

## Open issues

- Dockhand-home and cloudflared — kaywoz/home0ps#174
- `DOCKER-USER` rule inside the VM — kaywoz/home0ps#118
- Host firewall — kaywoz/home0ps#219
