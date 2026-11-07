# Media LXC security design

Unprivileged LXC on the storage host (MOS), **Debian 13**, own NIC on **VLAN 13 (IoT)**. Runs Jellyfin, Komga and Homey as containers ([`docker-compose/media/`](../docker-compose/media/compose.yaml)). Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Rebuild: [`config-files/mos/create-lxc.sh`](../config-files/mos/create-lxc.sh) on the storage host, then [`baseline.sh`](../config-files/ubuntu/baseline.sh) and [`docker-host.sh`](../config-files/ubuntu/docker-host.sh) inside — all passed `--verify` (2026-11-03). Build-out: kaywoz/home0ps#174, media mount kaywoz/home0ps#197.

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Network exposure

| Risk | Control |
|---|---|
| IoT devices reaching the LXC | Only Jellyfin **8096/tcp + 7359/udp** on the LXC's VLAN 13 address — an explicit exception to "ports on 127.0.0.1" so Apple TV and other VLAN 13 clients can play and discover (kaywoz, 2026-11-07). No DLNA, no host network for Jellyfin. Homey listens on the LAN by design (see below). No sshd in the LXC (verified: `baseline.sh` "no sshd (container)") |
| Over-broad tailnet access | `tag:media` + `tag:observed`; Komga and Jellyfin for phones/laptops as `svc:komga` / `svc:jellyfin` *(planned)*; Tailscale SSH: privusers, admin account only, 24h check, never root |
| Homey on host network | Needed for its LAN role (bridges, discovery on VLAN 13). Runs **without `privileged`** (Athom's guide uses it; dropped, kaywoz 2026-11-07), `cap_drop: [ALL]` plus only `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN` (D-Bus, avahi, go2rtc switching users / chroot / socket ownership), `/run` as tmpfs. **Not running yet:** its Matter daemon crashes in Docker-in-LXC even with `privileged` (#174) |

## Credentials

| Risk | Control |
|---|---|
| Media library tampering / cloud credential theft | The LXC holds **no** Filen credentials or crypt key: the storage host mounts the library read-only and binds it in read-only (decided 2026-11-07, #197). A compromised app can read the media, nothing more |
| Homey account | Homey's own login (cloud account); no secrets in git |

## Containment

| Risk | Control |
|---|---|
| App compromise → LXC | Container standard: non-root service uids (2001/2002, not the admin account's uid), `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges`, memory/pid limits *(untested on Homey: runs as the image's user)* |
| LXC compromise → storage host | Unprivileged LXC (root = uid 100000 on the host), device rules allow only tun + the render node, GPU group 44 mapped 1:1; break-glass `lxc-attach` from the host |
| GPU access | `/dev/dri/renderD128` only, via `group_add: 44` for Jellyfin |
| Komga native libraries | `/tmp` tmpfs with `exec` (SQLite JDBC loads its library from there) — the one tmpfs without `noexec` |
