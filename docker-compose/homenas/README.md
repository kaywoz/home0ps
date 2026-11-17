# Proposal: Docker stacks on the replacement homenas

> **Status: proposal — nothing is deployed or built.** kaywoz OKs (or changes) this before anything runs. The four compose files next to this README are drafts that validate (`docker compose config --quiet`), not deploy instructions.
>
> **Decided 2026-11-17 (kaywoz):** Docker runs directly on MOS and **all** stacks go there: no LXC and no VM stays ("go with mos only and prepare"). The #310 tests are done; verdict "viable, with conditions". What they settled is built in below; what's left is under [Before the build](#before-the-build) and [Go-live prerequisites](#go-live-prerequisites).

Four separate stacks for MOS on the replacement homenas (the 4-bay NVMe box tested in kaywoz/home0ps#310). The app lineup is kaywoz's (2026-11-16, extended the same day from `kaywoz/mos-templates`). On 2026-11-17 he moved the services that serve other services into the infra stack:

| Stack | File | Apps | Replaces | Zone |
|---|---|---|---|---|
| **media** | [`media/compose.yaml`](media/compose.yaml) | Jellyfin, Komga, Homey | the media LXC | VLAN 13 (IoT) |
| **infra** | [`infra/compose.yaml`](infra/compose.yaml) | the shared services: Tailscale sidecars (media and apps zones), cloudflared, the box's socket proxy and Beszel agent | the infra VM; the proxy and agent move from MOS-template deploys | each container in the zone it serves; internet access through VLAN 31 |
| **apps** | [`apps/compose.yaml`](apps/compose.yaml) | mediasort, paperless-ngx, CannonCommander, Immich, ArchiveBox, ArchiveTeam Warrior, Atuin, HedgeDoc, Filestash, RackPeek | the apps VM | VLAN 31 (apps) |
| **storage** | [`storage/compose.yaml`](storage/compose.yaml) | Kopia, Time Machine, RustFS, Scrutiny collector (run once a day from MOS cron, #103) | new (#43, #39) | the homenas's own network |

This follows the scenario in kaywoz/home0ps#314: Docker runs **directly on MOS**, one stack per zone, the zone stacks on a macvlan network on their VLAN sub-interface **with no host IP on those VLANs**. The MOS UI is the homenas's only management portal (#312). All three guests (the media LXC, the infra VM and the apps VM) move onto the new box (kaywoz, 2026-11-17; G1 resolved).

The candidates came from the 2026-11-13 discussion: a long list from kaywoz's GitHub stars, `kaywoz/mos-templates`, the MOS Hub catalogue (mos-official.net) and generic homeserver apps, then a short list checked against the Hub. kaywoz picked the four stacks above from it and added the rest from his MOS templates. Off the table for now: Pocket ID, Ollama, copyparty, the S3 alternatives to RustFS. The git-pull deployer (#314) isn't a stack; for now stacks are deployed through the MOS UI (below).

## Common design

### Zone stacks (media, infra, apps): reachability
- **Two macvlans** on VLAN sub-interfaces, no IP on the host side (kaywoz, 2026-11-17):
  - **`media-vlan13`:** only Jellyfin and Homey, as IoT members of VLAN 13 with fixed addresses.
  - **`apps-vlan31`:** every Docker container that needs the internet: both sidecars, cloudflared, mediasort, the archivers, and Immich ML for its first model download. "services needing internet use vlan31 for docker. vlan24 is for servers needing internet": **VLAN 24 isn't used by Docker.**
  - Everything else sits on internal bridges only. Traffic leaves through the VLAN, so the UniFi rules apply as they do to today's guests.
- **Everything else sits on `internal: true` bridges** (§8: internal when no egress and no ports). Each app gets a `proxy-<app>` network (app + sidecar). Apps with a database also get a `<app>-backend` network (app + database/Redis), so the sidecar never reaches a database. An internal bridge never gets a gateway, so the macvlan is always the default route where a container has both: no `gw_priority` (Engine ≥ 28) needed.
- **No `ports:`.** Macvlan containers can't be reached from the host (a kernel restriction, per Docker's macvlan docs), and port publishing doesn't work on macvlan or internal networks (moby source). So host-side `tailscale serve` to `127.0.0.1` can't reach them.
- **One Tailscale sidecar per zone with admin UIs** (`tailscale/tailscale`, userspace networking: no TUN, no `NET_ADMIN`). It joins the zone's macvlan and that zone's `proxy-<app>` networks, and advertises the Services from a serve-config file (`TS_SERVE_CONFIG`, `ipn.ServeConfig` JSON with a `Services` key; auto-advertised since containerboot 1.96). It keeps the zone's tag (`tag:media`, `tag:docker`), so the policy mostly stays. Both sidecars are **defined in the infra stack** (shared services) but each stays in its own zone: no container joins two zones' networks (I-Q4).
- **The infra stack owns the shared networks:** the macvlans (`media-vlan13`, `apps-vlan31`) and the `proxy-<app>` bridges the sidecars serve. The media and apps stacks join them as `external: true`, so **infra starts first**. The `<app>-backend` networks stay with their app's stack. Fixed addresses (`JELLYFIN_IP`, `HOMEY_IP`, `ARCHIVEBOX_IP`, `WARRIOR_IP`) stay in the zone stacks' `.env`; the subnets move to the infra stack's.
- **What the macvlan isolation buys:** a zone container can't reach the MOS host: not the MOS UI, not SMB/NFS, not the rclone remote control (not started at boot; CLI only, #316 closed).
- **What it costs:** on its macvlan IP every listening port of a container is open to that VLAN; Docker filters nothing there. Listed per service below.

| Alternative considered | Why not (for now) |
|---|---|
| Bridges + `127.0.0.1` ports + host `tailscale serve` (today's pattern) | Egress leaves from the homenas's own network instead of the zone's, and every container can reach the MOS host via the bridge gateway (MOS UI, SMB/NFS). Used only for the **storage** stack, whose services belong to the host anyway |
| MOS "Docker Local Host Access" plugin (shim) | **Tested, not usable** (#310 §7d): no settings; one shim on the main interface only, no IP of its own, the host's LAN routed through it as two /25s; nothing on the VLAN sub-interfaces, so host ↔ VLAN container stays blocked. Uninstalled |
| tsdproxy | Needs a network path to every target, so one instance would bridge all zones. Stable v2 makes a node per container, not Services (Services only in the v3 betas). Adds a dashboard, REST API, webhooks |
| DockTail | Native Services, read-only Docker API (works behind the socket proxy, `POST=0`), but drives a tailscaled that must reach the container, so it still needs the per-zone sidecar. Its documented sidecar uses `network_mode: host`. Parked: revisit if the number of Services grows |

### Container standard (CLAUDE.md §8) and MOS specifics
- **Applied everywhere** unless a service's table says otherwise: non-root `user:`, `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `pids_limit`, healthcheck where the image has or allows one, secrets as files (600, owned by the service uid), images on `:latest` (two exceptions under apps).
- **userns-remap — adopted** (kaywoz, 2026-11-17; #310 §7c, verified across a reboot; implementation in #325). Docker runs remapped daemon-wide, range pinned `dockremap:165536:65536` (LXC holds `root:100000`): **container uid N is host uid 165536 + N**. MOS runs `pre-start.sh` before Docker at boot, which writes the remap config into RAM `/etc`; `docker-userns.sh` re-checks it every minute from a MOS UI cron job. So a container's root is an unprivileged host uid if it escapes. **Distinct non-root uids per service stay on top of it**, so one compromised app still can't read another's data.
  - **Ownership:** appdata and secret files are owned by 165536 + the container uid (secret files 600). The compose comments say "owned 165536+N". The exempt services below keep real host uids.
  - **Autostart:** each stack needs **MOS autostart on**. `restart: unless-stopped` alone doesn't bring it back, because MOS's stop runs `docker stop`.
  - **Exemptions** (`userns_mode: host`; each needs a reason, and they belong in `security/homenas.md`'s "Container escape" row, which #325 adds):

    | # | Service | Why it can't run remapped |
    |---|---|---|
    | **R1** | socket proxy (infra) | it opens `docker.sock` as root; remapped root is host uid 165536, which has no access to the socket. Not in Docker's docs: reasoned from the socket's permissions, to confirm at build. `POST=0` stays the control (E6) |
    | **R2** | Beszel agent (infra) | `network_mode: host`, which Docker doesn't allow with a remapped container (docs.docker.com/engine/security/userns-remap, "known limitations"). It runs as 65534 |
    | **(R3)** | Jellyfin, Immich server | **only if the build test fails:** the render node's host group doesn't map into a remapped container, so `group_add: RENDER_GID` may not grant `/dev/dri/renderD128`. Two fixes: a boot step that sets the node's group to 165536 + `RENDER_GID` (keeps them remapped; it would go into #325's hook), or `userns_mode: host` for both (still non-root uids). Not an exemption in the draft |
    | **R5** | CannonCommander (apps) | it must write the same files as SMB: it runs as the Samba-only data user's uid:gid (`SHARE_UID`/`SHARE_GID`), which a remapped container can't be. An escape lands as that user, which owns `1.data` and `tmp` only. `cap_drop: [ALL]`, `no-new-privileges`, `read_only` stay (A-Q2) |
    | **R4** | Scrutiny collector (storage) | NVMe SMART needs `SYS_ADMIN` on the host's controller devices; a capability inside a remapped namespace doesn't count for host devices. Runs once a day, collector only (E5) |

  - Everything else runs remapped, including the root containers: Homey (E3) and Time Machine (E4) now run as host uid 165536, not host root.

Service uids:

| Range | Stack | uids |
|---|---|---|
| 20xx | media | 2001 Jellyfin, 2002 Komga (Homey: uid 0, M-Q1) |
| 21xx | apps | 2104 mediasort (as today), 2105 paperless, 2106 paperless Redis, 2107 CannonCommander (unused: it runs as the data user, R5), 2111 Immich server, 2112 Immich ML, 2113 Immich Postgres, 2114 Immich Valkey, 2121 Atuin, 2123 HedgeDoc |
| image uids | apps | ArchiveBox 911, ArchiveTeam Warrior 1000, RackPeek 1654, Filestash its image's own user (uid unverified, likely 1000). These images only work with their own uid. **Warrior and Filestash may share 1000** (A-Q10) |
| 22xx | infra | 2201 cloudflared, 2210 media sidecar, 2211 apps sidecar; Beszel agent 65534 (as today, not remapped: R2); socket proxy root (E6, not remapped: R1) |
| 23xx | storage | 2301 Kopia, 2302 RustFS, 2303 Time Machine share owner (the process is root) |

On the host each uid above is 165536 + uid (2001 → 167537), except the exemptions (R1, R2, R4, R5).

- **Paths:** MOS's root filesystem is RAM. All data lives under variables pointing at the pool (`${APPDATA}`, `${PHOTOS}`, `${BACKUPS}`, …). There's no `/srv/docker`, and no relative paths: the MOS UI runs each stack from its own folder (`appdata/compose_<stack>/`), so there are no relative paths to resolve.
- **One file per stack, not one per host:** decided (G2); §8's host layout has a homenas exception for it.
- **Monitoring:** one Docker daemon serves all stacks, so one read-only socket proxy (`kr-ccp-socketproxy-0301`, `POST=0`) and one Beszel agent (`kr-ccp-beszelagent-0201`) see every container. Both move from MOS-template deploys into the infra stack under the same names (`observed-hosts.md`: compose hosts keep them in their compose). **No Dozzle agent:** Dozzle already reads this host in remote-host mode through the proxy (verified 2026-11-08); an agent would need the full socket and allows exec (MISTAKES.md 2026-10-18). The guests' proxies, Hawser agents and native Beszel agents retire with the guests.
- **Logs:** MOS has no journald (Devuan). Container logs go to the monitoring host (G5, decided); Dozzle for live viewing.

### MOS: deploy, restarts, NIC and backups (from #310)

**Deploy procedure** (#310 §7b: the MOS UI creates, edits, starts/stops, updates and shows logs of stacks; there's no load-from-file):
1. **Before the first stack:** #325 is installed on the host, `docker-userns.sh --check` passes (Docker runs remapped), and appdata is empty or already re-owned.
2. Put the secret files and data folders on the pool, owned by **165536 + each service's uid** (tables per stack); R1 and R2 by their real uids.
3. **Per stack, infra first:** create the stack in the MOS UI, paste `compose.yaml` into its Compose YAML field and the filled-in `.env` values into its environment variables field, turn its **autostart on**, then start it. Order: **infra → storage → media → apps** (infra creates the networks the zone stacks join).
4. Later changes go through the UI too. MOS keeps **two copies** of each stack: the boot stick's (`/boot/config/system/docker/compose/<stack>/`) and the live one in appdata (`compose_<stack>/`). An edit on disk plus a restart applies, but leaves the stick copy stale, so edit in the UI, or treat the stick copy as stale until the next UI save. The repo's file stays the source of truth; what runs is checked against it with a `diff` (CLAUDE.md §2: merged isn't deployed).

**macvlan with a VLAN parent works from compose** (#310 §7b): a stack-defined macvlan with `parent: <nic>.13` makes Docker create the VLAN sub-interface itself, with no host IP on it.

**Restarts:** every service has `restart: unless-stopped`, but that alone isn't enough: MOS's stop runs `docker stop`, so stacks come back through **MOS autostart**, which must be on for each stack (#325). After a **reboot** MOS brought the test stacks back by itself, remapped (#310 §7c); after a **restart of Docker's init script** it didn't (#310 §7c): the containers stayed stopped until they were started from the UI. After such a restart, start the stacks from the UI in the order above.

**NIC watchdog:** every macvlan container (both sidecars, cloudflared, Jellyfin, Homey, mediasort, the archivers) hangs off the built-in NIC. A receive wedge takes them all off the network until the watchdog clears it, about a minute end to end (watchdog verified in #310); the homenas's own Tailscale is affected the same way. Whether `<nic>.<vlan>` and the containers recover after the watchdog's down/up is a pre-build test (below).

**Backups of appdata:** SnapRAID excludes `/appdata/`, `/docker/`, `/system/docker/`, `/rclone/` and `/rclone-cache/` (live, changing data; #310). So **appdata is protected only by the backup chain**: MOS Backup plugin → `2.backup` on the pool → Kopia → the USB disk and the Storage Box. The plugin has no encryption and no restore UI. **Restore with `tar --numeric-owner`**, so files keep their host uids (165536 + the service uid, e.g. 167537) instead of being mapped through user names that don't exist on MOS. The offsite copy has a gap of its own (#255, under go-live prerequisites).

## Stack 1 — media (VLAN 13), replaces the media LXC

| App | Container | Notes |
|---|---|---|
| Jellyfin | `kr-ccp-jellyfin-0201` | hardware transcoding on the N95's iGPU |
| Komga | `kr-ccp-komga-0201` | |
| Homey SHS | `kr-ccp-homey-0201` | the most important data to back up |
| Tailscale sidecar | `kr-ccp-tailscale-0101` | serves `svc:jellyfin`, `svc:komga` (tag:media); **defined in the infra stack** |

| Service | Deviation from the standard | Why |
|---|---|---|
| Jellyfin | `/dev/dri/renderD128` + `group_add` render GID | hardware transcoding (Jellyfin's Intel docs: no privileged, no capabilities) |
| Jellyfin | fixed IP on `media-vlan13`: **every port open on VLAN 13** (8096, 7359/udp; 8920/1900 only if HTTPS/DLNA get turned on) | Apple TV and other VLAN 13 clients play locally. Today's exception (8096 + 7359) becomes "all of Jellyfin's ports": keep HTTPS and DLNA off |
| Komga | `/tmp` tmpfs with `exec` | the SQLite JDBC driver loads its native library from `/tmp` (as today) |
| Komga | on `apps-vlan31` for internet access (M-Q2), next to the apps zone's containers | decided. Its UI (25600) is then open on VLAN 31, behind Komga's own login; same trade-off as the media sidecar. The sidecar still serves `svc:komga` through `proxy-komga` |
| Homey | **the hardening tested in #229, unchanged:** no `privileged`, `read_only`, `no-new-privileges`, `cap_drop: [ALL]` + `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN`, `/run` tmpfs | tested one capability at a time on the media LXC (2026-11-07). In that test, `docker top` showed Homey's core (`homey-shs`) and `homey-matter-daemon` as uid 0 in the container. D-Bus (100), avahi (101) and go2rtc dropped to their own users. Without userns-remap on MOS, uid 0 in the container is uid 0 on the host (M-Q1) |
| Homey | fixed macvlan IP on VLAN 13 instead of `network_mode: host` | host network would be the homenas's own network; discovery/mDNS should work on the macvlan L2 segment (to verify) |
| Homey | no healthcheck | none documented |

**Secrets:** none in this stack; the media sidecar's auth key is with the infra stack.

**Tailscale follow-ups** (own PRs, not built): `svc:jellyfin`, `svc:komga` already exist with `tag:media` auto-approval; the sidecar node takes over from the LXC node. Retire the Hawser grant (`tag:infra` → `tag:media:2376`) and the LXC's monitoring grants with the LXC.

**Migration from the media LXC:**
1. #310 passes and kaywoz decides the swap.
2. Back up `jellyfin/config`, `komga/config`, `homey/` (`jellyfin/cache` is rebuilt; the Hawser token retires).
3. **Re-own** the restored data to 165536 + the service uid (167537 Jellyfin, 167538 Komga): the LXC's files are owned by the LXC's own mapped uids.
4. **Homey: start from an empty data folder and re-pair** (#229: restored data crashed the Matter daemon and caused `EACCES` on `apps/`). Its Homey cloud backup is the first choice.
5. `media-mount.sh`: replace `LXCS=` with a list of containers to (re)start after a remount (a FUSE remount isn't seen through an existing bind mount). Own PR in `config-files/mos/`.
6. Start the stack with the LXC stopped; reuse Jellyfin's VLAN 13 address so Apple TV keeps pointing at it.
7. Check: playback with hardware transcoding (Intel GPU top plugin), Homey devices, `svc:jellyfin`/`svc:komga`, Dozzle.
8. Keep the LXC stopped (autostart off) for a week, then archive it.

**Open questions — media:**
- **M-Q1 — decided: Homey stays uid 0, as tested** (kaywoz, 2026-11-17): no `privileged`, four capabilities, and remap makes an escape host uid 165536, not root. Homey's D-Bus, avahi and Matter under remap are tested at build.
- **M-Q2 — decided: Komga gets internet access on `apps-vlan31`** (kaywoz, 2026-11-17), as G8 sets for every Docker container that needs it. No fixed address.

## Stack 2 — infra (shared services), replaces the infra VM

kaywoz, 2026-11-17: the infra stack holds the services that serve other services. The stack is where they're defined, not a network: each container stays in the zone it serves.

| App | Container | Zone / network | Serves |
|---|---|---|---|
| Tailscale sidecar, media | `kr-ccp-tailscale-0101` | `proxy-jellyfin` + `proxy-komga`; `apps-vlan31` for internet access (not a VLAN 13 member) | `svc:jellyfin`, `svc:komga` (tag:media) |
| Tailscale sidecar, apps | `kr-ccp-tailscale-0201` | `apps-vlan31` + the apps' `proxy-<app>` networks | the apps stack's Services and the mover's `tcp:8089` (tag:docker) |
| cloudflared | `kr-ccp-cloudflared-0101` | `apps-vlan31` | the Cloudflare Tunnel for user-facing apps, §8's second access plane; outbound only |
| socket proxy | `kr-ccp-socketproxy-0301` | plain bridge, `127.0.0.1:2375` | read-only Docker API for Dozzle and the Beszel agent; moves from its MOS-template deploy |
| Beszel agent | `kr-ccp-beszelagent-0201` | host network | host metrics and container stats for all stacks; moves from its MOS-template deploy |

**What I counted in:** everything whose job is to serve other containers or the host: the access path (sidecars, tunnel) and the box's observability (proxy, agent). **Not moved:** databases and Redis (they serve one app and stay on its `<app>-backend` network), Scrutiny (no container at all now: native collector, #103), the host's own tailscaled (a MOS plugin, not a container) and the storage services (Kopia, Time Machine, RustFS). Later candidates for this stack: Diun (#101) and Trivy (#102).

**Not here:** Dockhand-home. In the #314 scenario the MOS UI is the Docker UI and no other home guest is left for it to manage, so §8's Dockhand-home exception retires for home (I-Q1, decided). Dockhand-lab is unaffected.

| Service | Deviation | Why |
|---|---|---|
| infra stack | owns the zone macvlans and the `proxy-<app>` networks; media and apps join them as `external` | the sidecars are defined here, and a network is defined in one stack only. Start order: infra, then the zone stacks. Adding an app with a UI means a `proxy-<app>` network here and in the app's stack. `docker compose down` on infra can't remove networks while zone containers are attached |
| Tailscale sidecars | non-root + `read_only` | **unverified**: the image has no `USER`; userspace mode needs no TUN/caps (containerboot source); writable: state dir and `/tmp` (socket). Fallback: root with `cap_drop: [ALL]` |
| media sidecar | its internet access is on `apps-vlan31`, next to the apps zone's containers | Docker's egress is VLAN 31 (decided). Its only listener is `127.0.0.1:9002`, but a compromised media sidecar would sit between VLAN 31 and the media apps' internal bridges. Accepted with the decision; the alternative is a second Docker egress network |
| Tailscale sidecars | Service targets by container name (`kr-ccp-komga-0201`, …) | Docker's DNS resolves names on a shared network across stacks; compose service names are per-project aliases |
| cloudflared | on `apps-vlan31` (internet access), so open on VLAN 31 | it has no service port; metrics pinned to `127.0.0.1:20241` (container builds otherwise bind `0.0.0.0`) |
| cloudflared | `read_only` | no writable path documented; to verify at build |
| socket proxy | not `cap_drop`/non-root (E6); **not remapped** (R1) | as deployed and verified today: it needs root to open `docker.sock`; `POST=0` is the control |
| Beszel agent | `network_mode: host`, **not remapped** (R2) | upstream requirement for interface stats; `LISTEN` on the tailnet IP only, as today. Key and token now as files (`KEY_FILE`, `TOKEN_FILE`), where the template has them in MOS's variables |

cloudflared healthcheck: `cloudflared tunnel --metrics 127.0.0.1:20241 ready` (exec form; the image is distroless).

**Secrets** (kaywoz, on the host only):
- **Tailscale:** two tagged, single-use, pre-approved auth keys, one for `tag:media`, one for `tag:docker` (files, deleted after each node joins).
- **cloudflared:** the tunnel token as a file (`TUNNEL_TOKEN_FILE`, cloudflared ≥ 2025.4.0). Never `TUNNEL_TOKEN`: env vars are readable through the socket proxy.
- **Beszel agent:** `key` and `token` from the hub's "Add system" (owned 65534).

**Tailscale follow-ups** (own PRs, not built):
- The sidecar nodes keep the zone tags, so the Services, auto-approvers and grants listed under media and apps don't change because of this move.
- The socket proxy's `tailscale serve --tcp=2375` (host, `tag:storage`) and its `tag:monitoring` grant stay as they are.
- Retire `svc:dockhand`, the `tag:infra` → Hawser grant and its tests, and the infra VM's monitoring grants.

**Other follow-ups:** Cloudflare: the tunnel, public hostnames and Access policies (`iac/cloudflare/`).

**Migration:**
- **Infra stack first:** it creates the networks the zone stacks join.
- **Socket proxy and Beszel agent:** remove the MOS-template containers, then start the stack. Same names, same data folder; the agent needs its key and token as files first.
- **Dockhand:** nothing to carry over except its data, kept for rollback only (`dockhand/data` incl. `.encryption_key`). Retire the infra VM after the rollback window.

**Infra decisions** (kaywoz, 2026-11-17):
- **I-Q1 — decided: Dockhand-home retires for home** with this migration; the MOS UI is the home Docker UI. `CLAUDE.md` §8 records it (own PR). Dockhand-lab is unaffected.
- **I-Q2 — decided:** apps-zone apps are reached by cloudflared joining their `proxy-<app>` networks (inside one zone, bridges nothing). Jellyfin, if it ever goes public: a UniFi rule VLAN 31 → Jellyfin's VLAN 13 address, port 8096 only. No second cloudflared, and cloudflared never joins `proxy-jellyfin`.
- **I-Q3 — open (tbd):** no app is public for now; every UI is admin-only through Tailscale. cloudflared stays in the draft but joins no app network, so it reaches nothing until an app is picked. Candidates: Immich, paperless, CannonCommander, Jellyfin (Jellyfin through Cloudflare is a terms-of-service and client-compatibility question of its own).
- **I-Q4 — decided: one sidecar per zone**, both defined in the infra stack. Each keeps its zone's tag and networks. Cost: two containers, two auth keys, two nodes, and the infra stack owning the zone networks (start order, pre-build test (a)).

## Stack 3 — apps (VLAN 31), replaces the apps VM

| App | Container | Notes |
|---|---|---|
| mediasort | `kr-ccp-mediasort-0201` | the media classifier (#260), moved unchanged; Claude/OpenAI API (no local LLM: Ollama is dropped) |
| paperless-ngx | `kr-ccp-paperless-0101` + `kr-ccp-paperlessredis-0101` | SQLite + Redis, no Postgres, no Tika/Gotenberg |
| CannonCommander | `kr-ccp-cannoncommander-0101` | two-panel file manager from the MOS Hub (kaywoz's choice, replaces FileBrowser Quantum; it's a fork of it). Users, groups, 2FA, passkeys, OIDC |
| Immich | `kr-ccp-immich-0101`, `-immichml-0101`, `-immichdb-0101`, `-immichredis-0101` | photos; as the upstream release compose |
| ArchiveBox | `kr-ccp-archivebox-0101` | archives web pages |
| ArchiveTeam Warrior | `kr-ccp-archivewarrior-0101` | contributes to ArchiveTeam projects |
| Atuin | `kr-ccp-atuin-0101` | shell history sync server; SQLite, one container |
| HedgeDoc | `kr-ccp-hedgedoc-0101` | collaborative Markdown editor, the open-source line of HackMD (replaces Dillinger: A-Q9) |
| Filestash | `kr-ccp-filestash-0101` | file manager with storage backends (next to CannonCommander) |
| RackPeek | `kr-ccp-rackpeek-0101` | homelab inventory |
| Tailscale sidecar (infra stack) | `kr-ccp-tailscale-0201` | serves `svc:paperless`, `svc:cannoncommander`, `svc:immich`, `svc:archivebox`, `svc:archivewarrior`, `svc:atuin`, `svc:hedgedoc`, `svc:filestash`, `svc:rackpeek` and the mover's `tcp:8089` (tag:docker) |

| Service | Deviation | Why |
|---|---|---|
| mediasort | on `apps-vlan31` (egress to TMDB + the LLM provider): **8089 open on VLAN 31** | was `127.0.0.1` + tailnet only; it's bearer-token protected and only classifies names |
| mediasort | prebuilt `ghcr.io/kaywoz/mediasort:latest` | our own image, built in GitHub Actions (A-Q1); no build on the host |
| paperless-ngx | `read_only` via `S6_READ_ONLY_ROOT=1` + tmpfs `/run`, `/tmp`, `/var/cache/fontconfig` | rootless (`user:`) is supported upstream; read-only + rootless together isn't tested upstream |
| paperless-ngx | OCR language limited to the image's built-ins | extra languages install at start, which rootless mode can't do |
| paperless Redis | password in a config file, not `*_FILE` | Redis has no `*_FILE` support; healthcheck reads the file at run time (visible to processes inside that container only) |
| CannonCommander | the image's entrypoint bypassed (`entrypoint: tini -- /app/cannoncommander`), `user: "${SHARE_UID}:${SHARE_GID}"` (R5) | the entrypoint needs root: it chowns `/remotes`, adds a passwd entry and drops to `PUID` with `setpriv`. Without it, `config.yaml` is copied in by hand at deploy |
| CannonCommander | admin password (and any OIDC secret) in `config.yaml` (600), not env | a fresh install opens **without a sign-in** until a password is set (upstream changelog, v1.1.x). A password in the config closes that window; it's re-applied on every start. `CC_ADMIN_PASSWORD` in env would be readable through the socket proxy |
| CannonCommander | `http.port: 8080` in `config.yaml`, own healthcheck | port 80 as non-root needs `NET_BIND_SERVICE`; the image's healthcheck is hard-coded to 80 |
| CannonCommander | no `/dev/fuse`, `SYS_ADMIN`, `DAC_READ_SEARCH`, `DAC_OVERRIDE`, `apparmor:unconfined` (all in upstream's template) | they serve rclone mounts and Unraid's root-only paths. **rclone remotes are out of scope** (they would store cloud credentials in its config folder) unless kaywoz says otherwise |
| CannonCommander | `/remotes` source dropped from `config.yaml`; terminal, MCP server and WebDAV left off | the terminal is a shell in the container for admins, the MCP server gives AI assistants file access. All three are off until an admin switches them on |
| Immich server | `/dev/dri/renderD128` + render GID | Quick Sync transcoding |
| Immich server/ML | tag `release`, not `latest` | Immich publishes no `latest`; `release` is the moving tag |
| Immich Postgres | **a version tag** (`14-vectorchord0.4.3-pgvectors0.2.0`) | no `latest` or moving tag exists; upstream ties the extension version to each Immich release, so this tag must follow the release compose on upgrades (A-Q5). The one real exception to "images on `:latest`" |
| Immich (all) | `read_only` | not documented upstream for any service; Postgres needs tmpfs `/etc/postgresql` and `/var/run/postgresql`; to verify at build |
| Immich DB password | two files with the same value (server 2111, database 2113) | a 600 file has one owner. Both images export the value into the process environment at start (`start.sh`, `set-env.sh`), so the file only keeps it out of `docker inspect` |
| Immich ML | not enabled (A-Q4) | if ever enabled: on `apps-vlan31` for the first model download only; its API (3003) has no auth |
| Immich Valkey | `valkey/valkey:latest` with a password file | upstream pins `valkey:9` by digest; `:latest` per §8, so a major version bump can arrive unannounced |
| ArchiveBox | on `apps-vlan31`: **UI (5797) open on VLAN 31** | it fetches whatever it's given; it has its own login, and the public index/snapshots/add view are turned off (the image defaults the index to public) |
| ArchiveBox | uid 911 (the image's), **not `read_only`: exception E1** | its dirs are owned 911 (an arbitrary uid exits 3); `/opt/archivebox` holds the browser and plugin binaries and must be writable, so a tmpfs won't do and a volume would keep stale binaries across updates |
| ArchiveBox | admin account by a one-off `createsuperuser` | no `*_FILE` support; `ADMIN_PASSWORD` in env would be readable through the socket proxy |
| ArchiveTeam Warrior | on `apps-vlan31`; **UI (8001) has no auth** unless `http_password` is set | the password goes in a pre-made `projects/config.json` (600), not env |
| ArchiveTeam Warrior | uid 1000 (the image's), **not `read_only`: exception E2** | `/home/warrior/data` holds its baked-in `wget-at` binaries and must be writable; `no-new-privileges` also blocks the image's passwordless `sudo` |
| Atuin | `:latest` | upstream's `latest` lags (18.24.2 vs 18.24.8) and its docs warn against it; the moving release tag is `18.24`; `:latest` kept (A-Q8) |
| Atuin | SQLite (`sqlite:///config/atuin.db`) | kaywoz's choice; server support since 18.7/18.8. No database container, no password |
| HedgeDoc | uid 2123, `read_only` (to verify) | the entrypoint drops to its user only when started as root, so `user:` works; uploads and the DB folder are pre-owned |
| HedgeDoc | SQLite; session secret as a Docker secret named `sessionsecret` | HedgeDoc reads secrets by name from `/run/secrets/` (no `*_FILE` env) |
| HedgeDoc | `latest` = 1.12.0 | upstream withdrew 1.12.1 and 1.12.2 (a migration bug); its docs example still shows 1.12.2 |
| Filestash | image's own user (uid unverified), no `user:` override | its binary is mode 730: another uid can't execute it |
| Filestash | `/admin/setup` is open until an admin password is set | set it right after the first start; only reachable through the sidecar. The password is stored as a bcrypt hash in `config.json` |
| Filestash | no egress | backends on other hosts (SFTP, S3) would need it |
| RackPeek | uid 1654 (the image's); **no authentication on its UI** | Tailscale only, admins only |

**Secrets** (the sidecar's auth key is with the infra stack): mediasort: `token`, `tmdb`, `llm` (as today). paperless: `secret_key`, `redis_url`, `redis.conf`. CannonCommander: `config.yaml` (admin password). Immich: `db_password` (two copies), `redis_password`, `valkey.conf`. HedgeDoc: `session_secret`. ArchiveTeam Warrior: `projects/config.json` with `http_password`. Filestash: admin hash in its `config.json`. ArchiveBox: its superuser in its database.

**Tailscale follow-ups** (own PRs, not built):
- `iac/tailscale-services/`: add `svc:paperless`, `svc:cannoncommander`, `svc:immich`, `svc:atuin`, `svc:hedgedoc`, `svc:filestash` and `svc:rackpeek`.
- `svc:archivebox` and `svc:archivewarrior` already exist. Today the policy auto-approves them only when a `tag:storage` node advertises them, because they were planned on the homenas. Here, the apps zone's sidecar (a `tag:docker` node, defined in the infra stack) advertises them. So their `autoApprovers.services` entries in `policy.hujson` change from `tag:storage` to `tag:docker`; the names, URLs and the Service definitions in `iac/tailscale-services/` stay.
- Atuin's clients (every machine that syncs shell history) need a grant to `svc:atuin`.
- `policy.hujson`: auto-approve them for `tag:docker`, plus a grant per Service.
- The mover's grant (`tag:storage` → `tag:docker:8089`) and its tests stay; `CLASSIFIER_URL` becomes the sidecar's MagicDNS name.
- Retire the Hawser grant to `tag:docker`, the apps VM's monitoring grants and its Cockpit Service.

**Migration from the apps VM:**
1. Copy `mediasort/secrets/` and re-own it from the apps VM's remapped uid (102104) to 167640 (165536 + 2104).
2. Start mediasort, point the mover at the sidecar, run one dry run.
3. paperless, CannonCommander and Immich are new. Immich imports existing photos through its CLI or an external library (A-Q3).
4. Retire the apps VM once the mover has run cleanly for a day. Ollama's models are dropped with it.

**Apps decisions** (kaywoz, 2026-11-17):
- **A-Q1 — decided: mediasort is built in GitHub Actions and pushed to ghcr.io** (`ghcr.io/kaywoz/mediasort:latest`); the stack only pulls. The workflow is its own PR (needs the `workflow` scope check, §5). Our own supply chain, flagged in #314.
- **A-Q2 — CannonCommander, decided:** it serves two folders on the pool, `1.data` and `tmp` (`${SHARE_DATA}`, `${SHARE_TMP}`), mounted under `/mnt/user`, its default source. Local accounts (no OIDC provider exists). Maturity accepted (2026-11-17), no FileBrowser Quantum fallback.
  - **Write access — decided** (kaywoz, 2026-11-17): it writes to `1.data` and `tmp` only (two mounts, never the pool root). Both folders are owned by a **dedicated Samba-only user** (no shell, no home), which the MOS SMB shares for them use; CannonCommander runs **unremapped as that user's uid:gid** (`userns_mode: host`, R5), so SMB and CannonCommander write as the same owner. No ACLs (MOS has no `setfacl`, and mergerfs is mounted without `posix_acl`) and no shared group (`/etc` is RAM). Build steps: create the user in the MOS UI, `chown -R` both folders to it once (they're root-owned from the copy-in), set the shares to it. Done on the host 2026-11-17: MOS gives a Samba-only user the group `mos` (no other members), so both folders are 755 (the group can't write) and `SHARE_GID` is that group's gid. Anything else that writes there as root still leaves root-owned files CannonCommander can read but not change.
  - **First sign-in:** the current code opens with no sign-in on a fresh install; this draft bypasses the entrypoint and sets the admin password in `config.yaml`. If the image's own entrypoint is ever used, older releases print the password to the log (→ journald → LogTide): change it at first sign-in.
  - **To verify at build:** the server starts as 2107 with the entrypoint bypassed and `read_only` (needs `config.yaml`, writes its database and `cache/` under `/config`). Fallback: the image's entrypoint as root dropping to 2107 with `setpriv` and `CHOWN`/`FOWNER`/`SETUID`/`SETGID`, which becomes exception E8.
- **A-Q3 — decided:** existing photos come in as an **external library, read-only** (`${PHOTOS_LIBRARY}:/external:ro`), from a work folder on the same pool (exact path at build). `${PHOTOS}` stays Immich's own upload location. Under remap Immich (165536 + 2111) needs the folder world-readable or group access to read it.
- **A-Q4 — decided: Immich ML off** (profile `immich-ml` not enabled): the 8 GB box can't spare it. No smart search or face recognition; ML on another machine stays possible later.
- **A-Q5 — decided: the Immich Postgres version tag is accepted** (E7), updated with each Immich release.
- **A-Q6 — decided: upload through paperless's web UI or mobile app**, via `svc:paperless`. No consume share, no mail fetch: `consume/` stays internal to the container's volume.
- **A-Q8 — decided: Atuin on `:latest`** (§8), lag accepted.
- **A-Q9 — decided: HedgeDoc 1.x**, as drafted.
- **A-Q10 — decided: both file managers.** At build, check Filestash's uid (`docker run --rm --entrypoint id machines/filestash`); if it shares 1000 with the Warrior, give one its own `user:`.
- **A-Q11 — decided: no tinyauth in this phase.** RackPeek and the Warrior are limited to admins by grant (with ACL tests); the Warrior gets `http_password`. Revisit with public hostnames (Cloudflare Access).
- **A-Q12 — decided: the archivers stay on VLAN 31** with internet-only UniFi rules; revisit once the lab is built.

## Stack 4 — storage (the homenas's own network)

The host's own storage services. They're served by the host's own tailscaled (`tag:storage`, which already has `svc:kopia` and `svc:rustfs`), so this stack uses today's pattern: one bridge per app, ports on `127.0.0.1`, `tailscale serve` on the host. Time Machine is the exception.

| App | Container | Notes |
|---|---|---|
| Kopia | `kr-ccp-kopia-0101` | repository server for the other machines' backups (#43), repository on the pool |
| Time Machine | `kr-ccp-timemachine-0101` | SMB share for the Macs' backups |
| RustFS | `kr-ccp-rustfs-0101` | local S3 (#39) |

| Service | Deviation | Why |
|---|---|---|
| Kopia, RustFS | plain bridges (not internal), `127.0.0.1` ports | internal networks can't publish ports; neither app needs egress. A container on a plain bridge can reach the MOS host through the bridge gateway (S-Q1) |
| Kopia | TLS with its own certificate, served as `https+insecure://` | the repository server's gRPC needs TLS (Kopia docs). The earlier `svc:kopia` was UI-only over plain HTTP (MISTAKES.md 2026-10-18) |
| Kopia | UI login from an htpasswd file (`--htpasswd-file`, a hidden, older flag) | `--server-password` and `KOPIA_SERVER_PASSWORD` would land in the command line or env, both readable through the socket proxy |
| Kopia | repository password in `/app/config/*.kopia-password` (600) | Kopia has no `KOPIA_PASSWORD_FILE`. `KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=true` stores it there at the one-time `repository create/connect` |
| Kopia | `user:` non-root | the image has no `USER` or entrypoint script; the official compose runs root + privileged only for `kopia mount`, which isn't used. To verify at build |
| Time Machine | **runs as root, not `read_only`**, `cap_add` CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, NET_BIND_SERVICE | its entrypoint creates the SMB user, writes `smb.conf` and the avahi service into `/etc`, then runs smbd/nmbd/avahi. `privileged` isn't needed (not in upstream's compose). Capabilities read from the entrypoint, each to be confirmed at build |
| Time Machine | own macvlan address on the host's network (`storage-lan`) | MOS's own Samba holds 445 on the host, so host networking or a published 445 would clash. The image's author runs it on macvlan, and avahi then advertises it on that segment |
| RustFS | keys as files (`RUSTFS_*_KEY_FILE`) | never the built-in default `rustfsadmin`/`rustfsadmin` (it only warns) |
| RustFS | console CORS limited to its Service URL | the image defaults to `*` |

**Secrets:**
- **Kopia:** the repository password (stored by Kopia itself), `htpasswd`, and the TLS key and certificate (`openssl`, once).
- **Time Machine:** `password` (root-owned, 600).
- **RustFS:** `access_key` and `secret_key`.

**Tailscale follow-ups** (own PRs, not built):
- `svc:kopia` and `svc:rustfs` exist already. Add a Service for the S3 API, or decide it stays local (S-Q3).
- `svc:scrutiny` moves to the hub on the monitoring host (#103), plus one push grant `tag:storage` → `svc:scrutiny` with an ACL test. That's a new push flow to the monitoring host, outside §8's list (logtide-api, healthchecks, beszel), so it needs kaywoz's OK as an addition to that list.
- Grants per backup client to `svc:kopia`.
- Time Machine over the tailnet isn't covered: the host can't reach the macvlan address (S-Q2).

**Migration:**
- **Kopia and RustFS** are new on this box. If the current homenas runs either from a MOS template (#136 mentions RustFS), it has no registered container name. Its data is migrated or retired separately.
- **Time Machine:** existing Mac backups start fresh, or are copied over with the share's owner changed to 2303.

**Open questions — storage:**
- **S-Q1:** The host firewall (#219) comes before this stack. Kopia and RustFS on plain bridges can reach every port the MOS host listens on.
- **S-Q2:** Time Machine.
  - Which network are the Macs on? With the macvlan on the host's network, discovery works on that segment only; from other VLANs it's a manual connect (`smb://<address>/TimeMachine`) plus a UniFi rule.
  - Over the tailnet it would need its own sidecar.
  - The alternative is MOS's own Samba with a Time Machine share, if MOS supports `fruit:time machine` (unverified).
- **S-Q3:** RustFS's S3 API. Is it local only (the box's own backups, #30), or a Tailscale Service for other hosts (#28 "secure s3 endpoint")?
- **S-Q4 — Scrutiny: decided** (kaywoz, 2026-11-17, replaces #103's native collector): a **collector-only container**, run once a day by a MOS UI cron job (`docker-compose --profile cron run --rm`), pushing to the hub on the monitoring host. Not privileged: `SYS_RAWIO` + `SYS_ADMIN`, the NVMe controller devices only (no namespaces, so no direct disk read/write), `read_only`, no UI or port. Not remapped (R4); exception E5. Residual risk: NVMe admin commands through the controller, the same as a native collector running as root. Why a container: the MOS UI manages it, the image brings `smartctl`, and no binary has to live on an executable path (`/boot` is `noexec`).

## Exception register

Named exceptions to the container standard (CLAUDE.md §8). They go into the security summaries when built. Smaller deviations, like a tmpfs with `exec`, stay in the per-stack tables.

| # | Service | Exception | Why it can't meet the standard |
|---|---|---|---|
| **E1** | ArchiveBox | not `read_only`; fixed image uid 911 | `/opt/archivebox` holds the browser and plugin binaries and must be writable; its directories are owned 911 |
| **E2** | ArchiveTeam Warrior | not `read_only`; fixed image uid 1000; UI has no login unless `http_password` is set | `/home/warrior/data` holds its `wget-at` binaries and must be writable |
| E3 | Homey | core runs as uid 0, four capabilities | tested in #229; accepted (M-Q1). Remapped: host uid 165536 |
| E4 | Time Machine | root, not `read_only`, six capabilities | its entrypoint writes users and the Samba config into `/etc`. Remapped: host uid 165536 |
| E5 | Scrutiny collector (storage stack) | root, `SYS_RAWIO` + `SYS_ADMIN`, the NVMe controller devices, not remapped (R4) | NVMe SMART reads need them (Scrutiny README). Narrowed: collector only, controller devices only, `read_only`, runs for seconds once a day (S-Q4) |
| E6 | socket proxy (infra stack) | root (no `user:`), not remapped (R1): real host root | needs to open `docker.sock`; `POST=0` is the control, as today |
| E7 | Immich Postgres | a version tag instead of `:latest` | no moving tag exists; accepted (A-Q5) |
| (E8) | CannonCommander | only if the bypassed entrypoint fails at build: root entrypoint dropping to the data user, four capabilities | see A-Q2; not an exception in the draft |

### Mitigations for E1 and E2 (and what else is available)

**Already in the draft:**
- **Hardening that still applies:**
  - each runs as its image's non-root uid
  - `cap_drop: [ALL]`
  - `no-new-privileges` (which also blocks the Warrior's passwordless `sudo`)
  - Docker's default seccomp profile
  - memory and pid limits
- **Network isolation:** each sits on a macvlan, so neither can reach the MOS host at all: not its UI, its shares, or the rclone remote control.
- **Data:** each gets one data folder of its own, owned by its uid.

**Proposed, to add when built:**
1. **Read-only root anyway (to test):**
   - Set `read_only: true` and put only the binaries folder (`/opt/archivebox`, `/home/warrior/data`) on an **anonymous volume**. Docker seeds an anonymous volume from the image when it's created.
   - Renew it on every image update with `docker compose up -d --renew-anon-volumes <service>`, so the binaries never go stale.
   - Everything else stays read-only.
   - Unverified for both images. If it works, E1 and E2 shrink to one writable folder each.
2. **Egress filtering in UniFi** (the strongest control here; both have fixed addresses on VLAN 31): these two addresses may reach the internet only.
   - Block RFC1918 and the other VLANs, so a compromised archiver can't move sideways in the home network.
   - Turn on IDS/IPS for VLAN 31 if the gateway's throughput allows it (#202).
3. **Monitoring:**
   - **Beszel:** per-container CPU, memory and network graphs, with alerts to Slack on sustained spikes, for example a crawler gone wild or a miner.
   - **Dozzle:** for their logs.
   - **Diun (#101) and Trivy (#102):** image update notices and scheduled vulnerability scans of both images.
   - **Healthchecks:** for their health status.
4. **OS level:**
   - **userns-remap — in place** (#310 §7c, #325): uid 911 or 1000 inside the archivers is host uid 166447 or 166536, an unprivileged uid with no access to other services' data.
   - **AppArmor/SELinux** are not available on MOS's kernel (#174: "no AppArmor layer"; to re-check on the new box: `cat /sys/module/apparmor/parameters/enabled`).
   - **Pool mount options:** if the data pool can be mounted `nosuid,nodev`, a planted setuid file in a data folder is harmless. To check on MOS.
5. **Not proposed (proportionality):** runtime detection with Falco or Tetragon. They need privileged eBPF agents, and the kernel support on MOS is unknown.

## General open questions

- **G1 — resolved:** all stacks run on MOS; no LXC and no VM stays (kaywoz, 2026-11-17).
- **G2 — decided:** one compose file per stack, in its own folder (`docker-compose/homenas/<stack>/compose.yaml`), as drafted (kaywoz, 2026-11-17). Each folder is one MOS stack, so MOS's per-stack autostart, start and stop work as tested in #310. `CLAUDE.md` §8's host layout now has the homenas exception; #314's deployer works per stack folder.
- **G3 — decided:** the role is called **homenas** (kaywoz, 2026-11-17): storage, backups and the home Docker stacks. Renamed in `CLAUDE.md` §8, `README.md`, `SECURITY.md` and `security/homenas.md`. The Tailscale tag stays `tag:storage`. The rows that describe today's guests (media LXC, infra VM, apps VM) are rewritten with the build.
- **G4 — resolved:** the #310 tests are done (§7b: the UI manages stacks, macvlan with a VLAN parent works; §7c: remap persists through a pre-start hook, #325; §7d: shim not usable). What's left before the build is listed under [Before the build](#before-the-build).
- **G5 — decided:** container logs are sent to the monitoring host (kaywoz, 2026-11-17). The driver and transport (Docker `syslog` driver or a shipper) are chosen with the monitoring host's revival (#225).
- **G6 — done** (kaywoz, 2026-11-17): VLANs 13 and 31 are tagged on the homenas's switch port (24 isn't needed by Docker), with an address block per VLAN outside DHCP for the macvlans. VLAN 31's UniFi network is named `vlan31-apps` (no longer `docker`).
- **G7 — 8 GB of RAM** (kaywoz, 2026-11-16). Limits were cut for it; they are caps, not reservations.

  | Stack | Sum of `mem_limit`s |
  |---|---|
  | media | 2.8 GB (Jellyfin 1.5 GB, Komga 768 MB with a 512 MB heap, Homey 512 MB) |
  | infra | 0.6 GB (two sidecars, cloudflared, Beszel agent at 128 MB each; socket proxy 64 MB) |
  | apps | 5.4 GB without Immich ML (+1.5 GB with it) |
  | storage | 1.3 GB, plus 128 MB for the Scrutiny collector while it runs (seconds a day) |
  | **total** | **≈ 10 GB of caps** on an 8 GB box, before MOS itself, its RAM root filesystem and the rclone mount's buffers |

  - Caps over physical RAM are normal as long as the peaks don't line up. The peaks here are Jellyfin transcoding, paperless OCR (one worker now), ArchiveBox's Chromium and Immich imports. Real usage is unmeasured: watch it in Beszel for the first weeks and alert near the top.
  - Already done for 8 GB:
    - **Immich ML** is off (compose profile `immich-ml`, not enabled: A-Q4). Immich needs 6 GB with ML and 4 GB without. ML could run on another machine instead, e.g. the Mac mini, since Immich takes a remote ML URL (A-Q4).
    - **paperless** uses one worker.
    - **Komga's** heap is 512 MB.
  - If it's still tight, the next cuts are ArchiveBox and the Warrior (start them only when needed), then Filestash, which duplicates CannonCommander.
  - MOS's root filesystem is RAM. With 8 GB, anything writing to `/` (logs, a misplaced cache: MISTAKES.md 2026-11-10) eats into the same memory.
  - Check `nproc` and `free -g` on the box before going live.
- **G8 — internet access: decided** (kaywoz, 2026-11-17). Jellyfin and Homey are VLAN 13's IoT members. Docker containers that need the internet get an address on the VLAN 31 macvlan: "services needing internet use vlan31 for docker. vlan24 is for servers needing internet". Everything else stays on internal bridges. The per-address internet-only UniFi rules on VLAN 31 for the archivers still apply (mitigation 2 for E1/E2). The archivers stay on VLAN 31 (A-Q12).
  - Containers on the same macvlan reach each other directly: macvlan bridge mode switches between them inside the host, so UniFi never sees that traffic. On VLAN 31 the archivers can therefore reach the sidecars, cloudflared, mediasort and Immich ML (while it's connected) on any listening port; the UniFi rules only cover traffic that leaves the host.

## Before the build

Tests on the new box before the first real stack, each with throwaway containers:

- **(a) Boot order.** After a reboot, do the media and apps stacks come up when they depend on the infra stack's networks (`external: true`)? If MOS starts stacks in no fixed order and they fail, fall back to **each zone stack owning its own networks**: the zone sidecar then lives in that zone's stack again (I-Q4's cost changes accordingly).
- **(b) NIC watchdog bounce.** With macvlan stacks running, bounce the built-in NIC (down/up, as the watchdog does). Do `<nic>.<vlan>` and the macvlan containers recover by themselves, or do the stacks need a restart (then the watchdog gets a hook)?
- **(c) NIC name.** The built-in NIC is `eth0` only while the USB adapter is unplugged, and every `parent: <nic>.<vlan>` depends on that name. Leave the adapter out, or pin the interface name (by MAC) before the build.

## Go-live prerequisites

Security gaps from the 2026-11-17 attack-path review. None of them is in these files; each must be closed before the stacks hold real data:

- **#322 — UniFi:** block VLANs 13, 24 and 31 → the homenas's own address, so a zone container can't reach the host through the router either.
- **#219 — host firewall:** the storage stack's bridges → host, allowing only what's needed.
- **#255 — offsite copy that host root can't delete:** today root on the homenas holds the Storage Box login and the USB disk, so one compromised host can remove all copies (Storage Box snapshots or an append-only receiver).

## Unverified (checked at build, before anything goes live)

- **Tailscale sidecar:** non-root with `read_only`, and whether it serves Services in userspace mode to another container's IP. The containerboot source supports the config; the behaviour hasn't been tested.
- **`read_only`** for cloudflared, paperless-ngx (rootless), CannonCommander (entrypoint bypassed), Kopia, RustFS and all four Immich containers. Every writable path listed comes from reading the code, not from upstream docs.
- **Running as a non-root uid:** Immich Postgres with an arbitrary uid (nss_wrapper), and Kopia as non-root.
- **Image uids:** Filestash's (not read from the image layers).
- **Capability sets:** ArchiveTeam Warrior's per-project needs and target hosts.
- **Time Machine:** its capability set.
- **Networking:** Homey's discovery on a macvlan address.
- **MOS:** the Docker version (not recorded in #310). Settled by #310 and no longer listed here: the UI manages stacks, macvlan with a VLAN parent works, remap persists (#325).
- **Under remap:** the socket proxy's need for R1; the GPU for Jellyfin and Immich (R3); Homey and Time Machine as remapped root (D-Bus, avahi, Samba's user setup); whether the remapped uids can read the host's rclone media mount (FUSE `--uid`/`--gid` and `allow_other`); CannonCommander writing as the data user next to SMB (A-Q2, R5).
- **MOS stack copies** (still open from #310 §7b): which copy MOS uses if the appdata copy is missing (pool not mounted), and whether a UI save overwrites a direct disk edit.

## Follow-ups (not built; each its own PR after the OK)

- **Tailscale:** Services and grants per stack as listed above; retire Hawser, `svc:dockhand` and the guests' monitoring grants.
- **Cloudflare:** the tunnel(s), public hostnames and Access policies.
- **`config-files/mos/media-mount.sh`:** restart containers instead of LXCs after a remount.
- **Docs:** CLAUDE.md §8 (host roles, Dockhand-home, host layout), `SECURITY.md`, `security/*.md`.
- **`docker-compose/CONTAINERS.md`:** move the reserved names into the main table when built.
- **MOS feature request:** a working `docker_options` field (the UI resets it today), so remap wouldn't need the pre-start hook (#310 §7c; kaywoz files the report).
- **`security/homenas.md`:** the remap exemptions (R1, R2, and R3 if it comes to that) in the "Container escape" row, once #325 has merged.
- **Scrutiny (#103):** the hub on the monitoring host, the collector container + MOS UI cron job here, the push grant.
