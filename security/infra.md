# Infra VM security design

VM on the storage host (MOS), **Ubuntu**, own NIC by PCI passthrough on **VLAN 24 (infra)**. **Tier 0:** will run Dockhand-home (central Docker management for home) and the home cloudflared tunnel (CLAUDE.md §8, kaywoz/home0ps#174). Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`baseline.sh`](../config-files/ubuntu/baseline.sh) then [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) (both passed `--verify`); stack: [`docker-compose/infra/`](../docker-compose/infra/compose.yaml).

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Network exposure

| Risk | Control |
|---|---|
| Over-broad tailnet access | `tag:infra` + `tag:observed` + `tag:ssh`; nothing served yet. Inbound: monitoring host → tcp:45876 (Beszel agent) and tcp:2375 (read-only socket proxy, Dozzle); privusers are denied 2375 (ACL test) |
| Docker API exposure | `docker-socket-proxy` (`CONTAINERS`, `INFO`, `EVENTS`; `POST=0`) on bridge, `127.0.0.1:2375` only, exposed via `tailscale serve --tcp=2375` *(untested)* |
| Beszel agent listening | Host network, `LISTEN` on the tailnet IP only; pushes to `svc:beszel` *(untested)* |

## Containment

| Risk | Control |
|---|---|
| Container escape | `userns-remap` daemon-wide (`docker-host.sh`); exemptions: socket proxy (opens `docker.sock`) and Beszel agent (host network) |
| Monitoring tools controlling Docker | Read-only proxy (`POST=0`); the agent runs as uid 65534, read-only, no capabilities |

## Planned: Dockhand-home (kaywoz/home0ps#174)

Decided 2026-11-08, details in its PR:
- Its own VM through a **separate write-enabled socket proxy** (start/stop/restart, images, networks, volumes) on an internal network, **`EXEC` off** (no shell or file browser into containers here); never `docker.sock` in Dockhand itself.
- Storage host and apps VM through **Hawser, standard mode** (agent listens with a token on the tailnet IP, one grant `tag:infra` → those hosts tcp:2376). Hawser needs the full Docker socket: Dockhand ≈ root on those hosts (accepted, §8), and there `EXEC` can't be blocked by a proxy.
- UI only as `svc:dockhand`, auth enabled before serving (it ships with auth off), admins only.

## Accepted risks (this role)

- Tier 0 on a VM hosted by the storage host: whoever controls the storage host controls this VM.

## Open issues

- Dockhand-home and cloudflared — kaywoz/home0ps#174
- `DOCKER-USER` rule inside the VM — kaywoz/home0ps#118
- Host firewall — kaywoz/home0ps#219
