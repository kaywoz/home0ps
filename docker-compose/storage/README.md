# Proposal: Docker stacks on the replacement storage host

> **Status: proposal — nothing is deployed or built.** kaywoz OKs (or changes) this before anything runs. The four compose files next to this README are drafts that validate (`docker compose config --quiet`), not deploy instructions.

Four separate stacks for MOS on the replacement storage host (the 4-bay NVMe box tested in kaywoz/home0ps#310). The app lineup is kaywoz's (2026-11-16, extended the same day from `kaywoz/mos-templates`):

| Stack | File | Apps | Replaces | Zone |
|---|---|---|---|---|
| **media** | [`media/compose.yaml`](media/compose.yaml) | Jellyfin, Komga, Homey | the media LXC | VLAN 13 (IoT) |
| **infra** | [`infra/compose.yaml`](infra/compose.yaml) | cloudflared | the infra VM | VLAN 24 (infra, tier 0) |
| **apps** | [`apps/compose.yaml`](apps/compose.yaml) | mediasort, paperless-ngx, FileBrowser Quantum, Immich, ArchiveBox, ArchiveTeam Warrior, Atuin, Dillinger, Filestash, RackPeek | the apps VM | VLAN 31 (apps) |
| **storage** | [`storage/compose.yaml`](storage/compose.yaml) | Kopia, Time Machine, RustFS, Scrutiny, plus the box's socket proxy and Beszel agent | new (#43, #39, #103); the proxy and agent move from MOS-template deploys | the storage host's own network |

This follows the scenario in kaywoz/home0ps#314: Docker runs **directly on MOS**, one stack per zone, the zone stacks on a macvlan network on their VLAN sub-interface **with no host IP on those VLANs**. The MOS UI is the storage host's only management portal (#312). kaywoz asked for the media stack to replace the media LXC and to "do the same" for the infra VM and the apps VM. I read that as all of them moving onto the new box (G1).

The candidates came from the 2026-11-13 discussion: a long list from kaywoz's GitHub stars, `kaywoz/mos-templates`, the MOS Hub catalogue (mos-official.net) and generic homeserver apps, then a short list checked against the Hub. kaywoz picked the four stacks above from it and added the rest from his MOS templates. Off the table for now: Pocket ID, Ollama, copyparty, the S3 alternatives to RustFS. The git-pull deployer (#314) isn't a stack: it deploys the stacks, and stays its own entry pending the socket decision there.

## Common design

### Zone stacks (media, infra, apps): reachability
- **One macvlan per zone** (`media-vlan13`, `infra-vlan24`, `apps-vlan31`) on the VLAN sub-interface, no IP on the host side. Only containers that need **egress** or a **LAN presence** join it. Their traffic leaves through the zone's VLAN, so the UniFi zone rules apply as they do to today's guests.
- **Everything else sits on `internal: true` bridges** (§8: internal when no egress and no ports). Each app gets a `proxy-<app>` network (app + sidecar). Apps with a database also get a `<app>-backend` network (app + database/Redis), so the sidecar never reaches a database. An internal bridge never gets a gateway, so the macvlan is always the default route where a container has both: no `gw_priority` (Engine ≥ 28) needed.
- **No `ports:`.** Macvlan containers can't be reached from the host (a kernel restriction, per Docker's macvlan docs), and port publishing doesn't work on macvlan or internal networks (moby source). So host-side `tailscale serve` to `127.0.0.1` can't reach them.
- **One Tailscale sidecar per zone with admin UIs** (`tailscale/tailscale`, userspace networking: no TUN, no `NET_ADMIN`). It joins the zone's macvlan and the `proxy-<app>` networks, and advertises the Services from a serve-config file (`TS_SERVE_CONFIG`, `ipn.ServeConfig` JSON with a `Services` key; auto-advertised since containerboot 1.96). It keeps the zone's tag (`tag:media`, `tag:docker`), so the policy mostly stays. The infra stack has no UI, so no sidecar.
- **What the macvlan isolation buys:** a zone container can't reach the MOS host: not the MOS UI, not SMB/NFS, not the rclone remote control that listens unauthenticated on all interfaces today (#316).
- **What it costs:** on its macvlan IP every listening port of a container is open to that VLAN; Docker filters nothing there. Listed per service below.

| Alternative considered | Why not (for now) |
|---|---|
| Bridges + `127.0.0.1` ports + host `tailscale serve` (today's pattern) | Egress leaves from the storage host's own network instead of the zone's, and every container can reach the MOS host via the bridge gateway (MOS UI, SMB, the rclone rc in #316). Used only for the **storage** stack, whose services belong to the host anyway |
| MOS "Docker Local Host Access" plugin (shim) | Source (`ich777/mos-docker-shim`, `functions`): one shim on `eth0`/`br0` only, the host's own subnet routed through it as two hard-coded /25s, no VLAN sub-interfaces. Doesn't reach `<nic>.13/.24/.31`. #310 §7d still tests it |
| tsdproxy | Needs a network path to every target, so one instance would bridge all zones. Stable v2 makes a node per container, not Services (Services only in the v3 betas). Adds a dashboard, REST API, webhooks |
| DockTail | Native Services, read-only Docker API (works behind the socket proxy, `POST=0`), but drives a tailscaled that must reach the container, so it still needs the per-zone sidecar. Its documented sidecar uses `network_mode: host`. Parked: revisit if the number of Services grows |

### Container standard (CLAUDE.md §8) and MOS specifics
- **Applied everywhere** unless a service's table says otherwise: non-root `user:`, `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `pids_limit`, healthcheck where the image has or allows one, secrets as files (600, owned by the service uid), images on `:latest` (two exceptions under apps).
- **No userns-remap assumed.** MOS's Docker isn't remapped today (`uid_map 0 0 4294967295`, #174); #310 §7c tests whether it can be. Without it, `user:` uids are real host uids, and a container running as root is root on the storage host if it escapes. **Distinct uids per service**, so one compromised app can't read another's data:

| Range | Stack | uids |
|---|---|---|
| 20xx | media | 2001 Jellyfin, 2002 Komga, 2010 Tailscale sidecar (Homey: see M-Q1) |
| 21xx | apps | 2104 mediasort (as today), 2105 paperless, 2106 paperless Redis, 2107 FileBrowser Quantum, 2110 Tailscale sidecar, 2111 Immich server, 2112 Immich ML, 2113 Immich Postgres, 2114 Immich Valkey, 2121 Atuin, 2122 Atuin Postgres |
| image uids | apps | ArchiveBox 911, ArchiveTeam Warrior 1000, RackPeek 1654, Filestash and Dillinger their images' own users (uids unverified; Filestash likely 1000). These images only work with their own uid. **Warrior and Filestash may share 1000** (A-Q10) |
| 22xx | infra | 2201 cloudflared |
| 23xx | storage | 2301 Kopia, 2302 RustFS, 2303 Time Machine share owner (the process is root); Beszel agent 65534 (as today); Scrutiny root |

- **Paths:** MOS's root filesystem is RAM. All data lives under variables pointing at the pool (`${APPDATA}`, `${PHOTOS}`, `${BACKUPS}`, …). There's no `/srv/docker`, and no relative paths, so the files work wherever the stack's checkout sits (#314: same path inside and outside the deployer).
- **One file per stack, not one per host:** asked for explicitly; §8's host layout is one file per host (G2).
- **Monitoring:** one Docker daemon serves all stacks, so one read-only socket proxy (`kr-ccp-socketproxy-0301`, `POST=0`) and one Beszel agent (`kr-ccp-beszelagent-0201`) see every container. Both move from MOS-template deploys into the storage stack under the same names (`observed-hosts.md`: compose hosts keep them in their compose). **No Dozzle agent:** Dozzle already reads this host in remote-host mode through the proxy (verified 2026-11-08); an agent would need the full socket and allows exec (MISTAKES.md 2026-10-18). The guests' proxies, Hawser agents and native Beszel agents retire with the guests.
- **Logs:** MOS has no journald (Devuan). Container logs stay in Docker's default driver and Dozzle until log shipping is revived (G5).

## Stack 1 — media (VLAN 13), replaces the media LXC

| App | Container | Notes |
|---|---|---|
| Jellyfin | `kr-ccp-jellyfin-0201` | hardware transcoding on the N95's iGPU |
| Komga | `kr-ccp-komga-0201` | |
| Homey SHS | `kr-ccp-homey-0201` | the most important data to back up |
| Tailscale sidecar | `kr-ccp-tailscale-0101` | serves `svc:jellyfin`, `svc:komga` (tag:media) |

| Service | Deviation from the standard | Why |
|---|---|---|
| Jellyfin | `/dev/dri/renderD128` + `group_add` render GID | hardware transcoding (Jellyfin's Intel docs: no privileged, no capabilities) |
| Jellyfin | fixed IP on `media-vlan13`: **every port open on VLAN 13** (8096, 7359/udp; 8920/1900 only if HTTPS/DLNA get turned on) | Apple TV and other VLAN 13 clients play locally. Today's exception (8096 + 7359) becomes "all of Jellyfin's ports": keep HTTPS and DLNA off |
| Komga | `/tmp` tmpfs with `exec` | the SQLite JDBC driver loads its native library from `/tmp` (as today) |
| Komga | no egress (internal bridge only) | Komga reads embedded metadata; if it turns out to need the internet, it joins `media-vlan13` and is then open on VLAN 13 (M-Q2) |
| Homey | **the hardening tested in #229, unchanged:** no `privileged`, `read_only`, `no-new-privileges`, `cap_drop: [ALL]` + `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN`, `/run` tmpfs | tested one capability at a time on the media LXC (2026-11-07). In that test, `docker top` showed Homey's core (`homey-shs`) and `homey-matter-daemon` as uid 0 in the container. D-Bus (100), avahi (101) and go2rtc dropped to their own users. Without userns-remap on MOS, uid 0 in the container is uid 0 on the host (M-Q1) |
| Homey | fixed macvlan IP on VLAN 13 instead of `network_mode: host` | host network would be the storage host's own network; discovery/mDNS should work on the macvlan L2 segment (to verify) |
| Homey | no healthcheck | none documented |
| Tailscale sidecar | non-root + `read_only` | **unverified**: the image has no `USER`; userspace mode needs no TUN/caps (containerboot source); writable: state dir and `/tmp` (socket). Fallback: root with `cap_drop: [ALL]` |

**Secrets** (kaywoz, on the host only): a tagged, single-use, pre-approved Tailscale auth key for `tag:media` (file, deleted after the node joins).

**Tailscale follow-ups** (own PRs, not built): `svc:jellyfin`, `svc:komga` already exist with `tag:media` auto-approval; the sidecar node takes over from the LXC node. Retire the Hawser grant (`tag:infra` → `tag:media:2376`) and the LXC's monitoring grants with the LXC.

**Migration from the media LXC:**
1. #310 passes and kaywoz decides the swap.
2. Back up `jellyfin/config`, `komga/config`, `homey/` (`jellyfin/cache` is rebuilt; the Hawser token retires).
3. **Re-own** the restored data to the service uids (2001, 2002): the LXC's files are owned by mapped uids, and MOS has no remap unless §7c says otherwise.
4. **Homey: start from an empty data folder and re-pair** (#229: restored data crashed the Matter daemon and caused `EACCES` on `apps/`). Its Homey cloud backup is the first choice.
5. `media-mount.sh`: replace `LXCS=` with a list of containers to (re)start after a remount (a FUSE remount isn't seen through an existing bind mount). Own PR in `config-files/mos/`.
6. Start the stack with the LXC stopped; reuse Jellyfin's VLAN 13 address so Apple TV keeps pointing at it.
7. Check: playback with hardware transcoding (Intel GPU top plugin), Homey devices, `svc:jellyfin`/`svc:komga`, Dozzle.
8. Keep the LXC stopped (autostart off) for a week, then archive it.

**Open questions — media:**
- **M-Q1 — Homey as uid 0.** The tested setup removes `privileged` and all but four capabilities, but the core still runs as uid 0, which on MOS without remap is host uid 0 if it escapes. I found no record of a run with a non-root `user:`. Options: (a) accept, as tested; (b) test `user:` with a non-root uid on the media LXC now: D-Bus, avahi and go2rtc switch users themselves and may fail without root; (c) wait for #310 §7c (userns-remap).
- **M-Q2:** Does Komga need egress?

## Stack 2 — infra (VLAN 24), replaces the infra VM

| App | Container | Notes |
|---|---|---|
| cloudflared | `kr-ccp-cloudflared-0101` | the Cloudflare Tunnel for user-facing apps, §8's second access plane; outbound only |

**Not here:** Dockhand-home. In the #314 scenario the MOS UI is the Docker UI and no other home guest is left for it to manage, so §8's Dockhand-home exception retires for home (I-Q1). Dockhand-lab is unaffected.

| Service | Deviation | Why |
|---|---|---|
| cloudflared | on `infra-vlan24` (egress), so open on VLAN 24 | it has no service port; metrics pinned to `127.0.0.1:20241` (container builds otherwise bind `0.0.0.0`) |
| cloudflared | `read_only` | no writable path documented; to verify at build |

Healthcheck: `cloudflared tunnel --metrics 127.0.0.1:20241 ready` (exec form; the image is distroless).

**Secrets:** the tunnel token as a file (`TUNNEL_TOKEN_FILE`, cloudflared ≥ 2025.4.0). Never `TUNNEL_TOKEN`: env vars are readable through the socket proxy.

**Follow-ups:**
- Retire `svc:dockhand`, the `tag:infra` → Hawser grant and its tests, and the infra VM's monitoring grants.
- Cloudflare: the tunnel, public hostnames and Access policies (`iac/cloudflare/`).

**Migration:** nothing to carry over except Dockhand's data, kept for rollback only (`dockhand/data` incl. `.encryption_key`). Retire the infra VM after the rollback window.

**Open questions — infra:**
- **I-Q1:** Retire Dockhand-home for home, as #314 proposes? (A CLAUDE.md §8 change in its own PR.)
- **I-Q2:** How does cloudflared reach apps in other zones?
  - (a) A UniFi rule VLAN 24 → the app's address, per port. The app then needs a macvlan address, so it's open on its VLAN.
  - (b) A cloudflared per stack, on that stack's internal `proxy-<app>` networks.
  - (c) The infra cloudflared joins the other stacks' internal networks. That bridges zones; not recommended.

  My pick: **(b)**. Each zone stays self-contained, and the infra stack becomes the place for one shared tunnel only if one is ever needed.
- **I-Q3:** Which apps are user-facing (tunnel + Access) and which are admin-only (Tailscale)? Candidates for the tunnel: Immich, paperless, FileBrowser Quantum, Jellyfin. Jellyfin through Cloudflare is a terms-of-service and client-compatibility question of its own.

## Stack 3 — apps (VLAN 31), replaces the apps VM

| App | Container | Notes |
|---|---|---|
| mediasort | `kr-ccp-mediasort-0201` | the media classifier (#260), moved unchanged; Claude/OpenAI API (no local LLM: Ollama is dropped) |
| paperless-ngx | `kr-ccp-paperless-0101` + `kr-ccp-paperlessredis-0101` | SQLite + Redis, no Postgres, no Tika/Gotenberg |
| FileBrowser Quantum | `kr-ccp-filebrowser-0101` | files through a browser; OIDC capable |
| Immich | `kr-ccp-immich-0101`, `-immichml-0101`, `-immichdb-0101`, `-immichredis-0101` | photos; as the upstream release compose |
| ArchiveBox | `kr-ccp-archivebox-0101` | archives web pages |
| ArchiveTeam Warrior | `kr-ccp-archivewarrior-0101` | contributes to ArchiveTeam projects |
| Atuin | `kr-ccp-atuin-0101` + `kr-ccp-atuindb-0101` | shell history sync server; Postgres as in the template |
| Dillinger | `kr-ccp-dillinger-0101` | Markdown editor |
| Filestash | `kr-ccp-filestash-0101` | file manager with storage backends (next to FileBrowser Quantum) |
| RackPeek | `kr-ccp-rackpeek-0101` | homelab inventory |
| Tailscale sidecar | `kr-ccp-tailscale-0201` | serves `svc:paperless`, `svc:filebrowser`, `svc:immich`, `svc:archivebox`, `svc:archivewarrior`, `svc:atuin`, `svc:dillinger`, `svc:filestash`, `svc:rackpeek` and the mover's `tcp:8089` (tag:docker) |

| Service | Deviation | Why |
|---|---|---|
| mediasort | on `apps-vlan31` (egress to TMDB + the LLM provider): **8089 open on VLAN 31** | was `127.0.0.1` + tailnet only; it's bearer-token protected and only classifies names |
| mediasort | `build:` on the host | our own image; a host build needs the repo checkout, and #314's deployer option B can't build (A-Q1) |
| paperless-ngx | `read_only` via `S6_READ_ONLY_ROOT=1` + tmpfs `/run`, `/tmp`, `/var/cache/fontconfig` | rootless (`user:`) is supported upstream; read-only + rootless together isn't tested upstream |
| paperless-ngx | OCR language limited to the image's built-ins | extra languages install at start, which rootless mode can't do |
| paperless Redis | password in a config file, not `*_FILE` | Redis has no `*_FILE` support; healthcheck reads the file at run time (visible to processes inside that container only) |
| FileBrowser Quantum | admin password and OIDC secret in `config.yaml` (600), not env | no `*_FILE` support; env would be readable through the socket proxy. The admin password in the config is re-applied on every start |
| FileBrowser Quantum | `http.port: 8080` in `config.yaml`, own healthcheck | port 80 as non-root needs `NET_BIND_SERVICE`; the image's healthcheck is hard-coded to 80 |
| FileBrowser Quantum | `read_only`, cache dir on a tmpfs | not documented upstream; the cache dir must be fast (startup speed test) |
| Immich server | `/dev/dri/renderD128` + render GID | Quick Sync transcoding |
| Immich server/ML | tag `release`, not `latest` | Immich publishes no `latest`; `release` is the moving tag |
| Immich Postgres | **a version tag** (`14-vectorchord0.4.3-pgvectors0.2.0`) | no `latest` or moving tag exists; upstream ties the extension version to each Immich release, so this tag must follow the release compose on upgrades (A-Q5). The one real exception to "images on `:latest`" |
| Immich (all) | `read_only` | not documented upstream for any service; Postgres needs tmpfs `/etc/postgresql` and `/var/run/postgresql`; to verify at build |
| Immich DB password | two files with the same value (server 2111, database 2113) | a 600 file has one owner. Both images export the value into the process environment at start (`start.sh`, `set-env.sh`), so the file only keeps it out of `docker inspect` |
| Immich ML | no egress (internal only); models need egress on first use | its API (3003) has no auth, so it never sits on a VLAN. Models: connect it to `apps-vlan31` while they download, then disconnect (A-Q4) |
| Immich Valkey | `valkey/valkey:latest` with a password file | upstream pins `valkey:9` by digest; `:latest` per §8, so a major version bump can arrive unannounced |
| ArchiveBox | on `apps-vlan31`: **UI (5797) open on VLAN 31** | it fetches whatever it's given; it has its own login, and the public index/snapshots/add view are turned off (the image defaults the index to public) |
| ArchiveBox | uid 911 (the image's), **not `read_only`** | its dirs are owned 911 (an arbitrary uid exits 3); `/opt/archivebox` holds the browser and plugin binaries and must be writable, so a tmpfs won't do and a volume would keep stale binaries across updates |
| ArchiveBox | admin account by a one-off `createsuperuser` | no `*_FILE` support; `ADMIN_PASSWORD` in env would be readable through the socket proxy |
| ArchiveTeam Warrior | **runs code it downloads**: project pipelines are `git pull`ed from GitHub and executed in-process | that is a risky workload under §8 (A-Q7) |
| ArchiveTeam Warrior | on `apps-vlan31`; **UI (8001) has no auth** unless `http_password` is set | the password goes in a pre-made `projects/config.json` (600), not env |
| ArchiveTeam Warrior | uid 1000 (the image's), not `read_only` | `/home/warrior/data` holds its baked-in `wget-at` binaries and must be writable; `no-new-privileges` also blocks the image's passwordless `sudo` |
| Atuin | `:latest` | upstream's `latest` lags (18.24.2 vs 18.24.8) and its docs warn against it; the moving release tag is `18.24` (A-Q8) |
| Atuin Postgres | `postgres:latest` (the template uses `postgres:18`), data mounted at `/var/lib/postgresql` | on a new major version the image uses a new PGDATA subfolder and starts an **empty** cluster next to the old one, which then needs `pg_upgrade` (A-Q8) |
| Atuin / its Postgres | the DB password as two files (2121, 2122) | as for Immich: one owner per 600 file |
| Dillinger | **version tag `3.39.1` (2021)**, image's own user | no `latest`; newer tags are arm64-only; upstream dropped its Dockerfile; the linuxserver image is deprecated; the MOS template was removed as broken (A-Q9) |
| Dillinger | `read_only` unverified | the image chowns `/public`, so the app may write there |
| Filestash | image's own user (uid unverified), no `user:` override | its binary is mode 730: another uid can't execute it |
| Filestash | `/admin/setup` is open until an admin password is set | set it right after the first start; only reachable through the sidecar. The password is stored as a bcrypt hash in `config.json` |
| Filestash | no egress | backends on other hosts (SFTP, S3) would need it |
| RackPeek | uid 1654 (the image's); **no authentication on its UI** | Tailscale only, admins only |

**Secrets:** a Tailscale auth key for `tag:docker`. mediasort: `token`, `tmdb`, `llm` (as today). paperless: `secret_key`, `redis_url`, `redis.conf`. FileBrowser Quantum: `config.yaml`. Immich: `db_password` (two copies), `redis_password`, `valkey.conf`. Atuin: `db_password` (two copies). ArchiveTeam Warrior: `projects/config.json` with `http_password`. Filestash: admin hash in its `config.json`. ArchiveBox: its superuser in its database.

**Tailscale follow-ups** (own PRs, not built):
- `iac/tailscale-services/`: add `svc:paperless`, `svc:filebrowser`, `svc:immich`, `svc:atuin`, `svc:dillinger`, `svc:filestash` and `svc:rackpeek`. `svc:archivebox` and `svc:archivewarrior` exist for `tag:storage`; they move to `tag:docker`.
- Atuin's clients (every machine that syncs shell history) need a grant to `svc:atuin`.
- `policy.hujson`: auto-approve them for `tag:docker`, plus a grant per Service.
- The mover's grant (`tag:storage` → `tag:docker:8089`) and its tests stay; `CLASSIFIER_URL` becomes the sidecar's MagicDNS name.
- Retire the Hawser grant to `tag:docker`, the apps VM's monitoring grants and its Cockpit Service.

**Migration from the apps VM:**
1. Copy `mediasort/secrets/` and re-own it from the remapped uid (102104) to 2104.
2. Start mediasort, point the mover at the sidecar, run one dry run.
3. paperless, FileBrowser Quantum and Immich are new. Immich imports existing photos through its CLI or an external library (A-Q3).
4. Retire the apps VM once the mover has run cleanly for a day. Ollama's models are dropped with it.

**Open questions — apps:**
- **A-Q1:** mediasort's image. Build it on the host (needs the checkout and a deployer that can build), or build it in GitHub Actions and push to ghcr.io? The second means our own supply chain, flagged in #314.
- **A-Q2:** FileBrowser Quantum. Which folders does it serve (`${SHARES}`)? Local accounts or OIDC, and which provider (Pocket ID is off the list)?
- **A-Q3:** Immich: where do the photos live (`${PHOTOS}`), and do existing photos come in as an external library (read-only) or by upload?
- **A-Q4:** Immich ML on the N95: CPU (as drafted), OpenVINO (`release-openvino` + `/dev/dri`; upstream warns about integrated GPUs on low-RAM hosts), or ML off (Immich needs 6 GB minimum, 4 GB without ML)? Models need egress the first time; accept a permanent VLAN 31 address for ML instead?
- **A-Q5:** The Immich Postgres version tag. Accept this one exception to `:latest`, updated with each Immich release?
- **A-Q6:** paperless: how do scans reach `consume/` (FileBrowser upload, an SMB share, scanner e-mail)?
- **A-Q7 — ArchiveTeam Warrior on home hardware.** It downloads and executes ArchiveTeam's project code, the "risky workload" §8 sends to the XCP-ng lab. The earlier long list also placed it in the lab. Keep it here as asked, or put it in the lab?
- **A-Q8 — Atuin.** (a) `:latest` (lags releases) or the `18.24` release tag? (b) Postgres as in the template (`:latest` and the major-version PGDATA trap above), or Atuin's SQLite backend (`sqlite:///config/atuin.db`, server support since 18.7–18.8), which drops the database container entirely? My pick: SQLite.
- **A-Q9 — Dillinger.** Upstream has no current Docker image: the only amd64 build is 3.39.1 from 2021, and the template was removed as broken. Keep it on that old version, or drop it?
- **A-Q10 — two file managers and shared uids.** Filestash next to FileBrowser Quantum: both, as asked? Filestash's and Warrior's image uids may both be 1000; same uid means one compromised app can read the other's files where permissions allow. Check `docker run --rm --entrypoint id machines/filestash` at build.

## Stack 4 — storage (the storage host's own network)

The host's own storage services. They're served by the host's own tailscaled (`tag:storage`, which already has `svc:kopia` and `svc:rustfs`), so this stack uses today's pattern: one bridge per app, ports on `127.0.0.1`, `tailscale serve` on the host. Time Machine is the exception.

| App | Container | Notes |
|---|---|---|
| Kopia | `kr-ccp-kopia-0101` | repository server for the other machines' backups (#43), repository on the pool |
| Time Machine | `kr-ccp-timemachine-0101` | SMB share for the Macs' backups |
| Scrutiny | `kr-ccp-scrutiny-0101` | SMART health of the four NVMe drives (#103); omnibus as in the template |
| socket proxy | `kr-ccp-socketproxy-0301` | read-only Docker API for Dozzle and Beszel; moves from its MOS-template deploy |
| Beszel agent | `kr-ccp-beszelagent-0201` | host metrics and container stats; moves from its MOS-template deploy |
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
| Scrutiny | **root, not `read_only`, `SYS_RAWIO` + `SYS_ADMIN`**, the four NVMe devices, `/run/udev` read-only | the omnibus image runs InfluxDB, the web app and cron as root under s6. NVMe SMART needs `SYS_ADMIN`, which Scrutiny's own docs say allows host compromise (S-Q4) |
| Scrutiny | **no authentication** on its UI and API | Tailscale only (`svc:scrutiny`, admins); InfluxDB (8086) not published |
| socket proxy | not `cap_drop`/non-root | as deployed and verified today: it needs root to open `docker.sock`; `POST=0` is the control |
| Beszel agent | `network_mode: host` | upstream requirement for interface stats; `LISTEN` on the tailnet IP only, as today. Key and token now as files (`KEY_FILE`, `TOKEN_FILE`), where the template has them in MOS's variables |

**Secrets:**
- **Kopia:** the repository password (stored by Kopia itself), `htpasswd`, and the TLS key and certificate (`openssl`, once).
- **Time Machine:** `password` (root-owned, 600).
- **Beszel agent:** `key` and `token` from the hub's "Add system" (owned 65534).
- **RustFS:** `access_key` and `secret_key`.

**Tailscale follow-ups** (own PRs, not built):
- `svc:kopia`, `svc:rustfs` and `svc:scrutiny` exist already. Add a Service for the S3 API, or decide it stays local (S-Q3).
- The socket proxy's `tailscale serve --tcp=2375` and its `tag:monitoring` grant stay as they are.
- Grants per backup client to `svc:kopia`.
- Time Machine over the tailnet isn't covered: the host can't reach the macvlan address (S-Q2).

**Migration:**
- **Socket proxy and Beszel agent:** remove the MOS-template containers, then start the stack. Same names, same data folder; the agent needs its key and token as files first.
- **Kopia and RustFS** are new on this box. If the current storage host runs either from a MOS template (#136 mentions RustFS), it has no registered container name. Its data is migrated or retired separately.
- **Time Machine:** existing Mac backups start fresh, or are copied over with the share's owner changed to 2303.

**Open questions — storage:**
- **S-Q1:** The host firewall (#219) and the rclone rc fix (#316) come before this stack. Kopia and RustFS on plain bridges can reach every port the MOS host listens on.
- **S-Q2:** Time Machine.
  - Which network are the Macs on? With the macvlan on the host's network, discovery works on that segment only; from other VLANs it's a manual connect (`smb://<address>/TimeMachine`) plus a UniFi rule.
  - Over the tailnet it would need its own sidecar.
  - The alternative is MOS's own Samba with a Time Machine share, if MOS supports `fruit:time machine` (unverified).
- **S-Q3:** RustFS's S3 API. Is it local only (the box's own backups, #30), or a Tailscale Service for other hosts (#28 "secure s3 endpoint")?
- **S-Q4 — Scrutiny with `SYS_ADMIN` as root on the storage host.**
  - (a) Accept, as in the template.
  - (b) Keep only the collector here (also root, also `SYS_ADMIN`, but no web UI and no InfluxDB) and put the hub on the monitoring host. That's where the earlier long list put it, and it matches "monitoring reads everything".
  - (c) Skip Scrutiny and use the SMART data Beszel and the MOS UI already show.

## General open questions

- **G1:** Do all stacks run on MOS (my reading of the request and #314's scenario), or do the infra and apps VMs stay?
- **G2:** One compose file per stack (as here), or one per host (§8 host layout)? CLAUDE.md §8 and #314 get updated to match.
- **G3:** §8 calls the storage host "storage only". These stacks make it the home Docker host. That's the #314 scenario, but §8's host roles, `SECURITY.md` and `security/*.md` need rewriting in the same change as the build.
- **G4:** Build before #310 §7b–§7e are done? They decide whether the MOS UI manages compose stacks, whether macvlan with a VLAN parent works from MOS, and whether userns-remap is possible. My pick: **wait**.
- **G5:** Container logs off-box on MOS (no journald). Use Docker's `syslog` driver to the monitoring host, or wait for log shipping?
- **G6:** VLANs 13/24/31 tagged on the storage host's switch port, and a small address block per VLAN outside DHCP for the macvlans. Today the guests' VLANs come from PCI passthrough and the LXC's own NIC.
- **G7:** RAM and CPU. Immich (6–8 GB recommended), paperless OCR and Jellyfin transcoding share a 4-core N95 with the storage role. The `mem_limit`s here add up to about 31 GB of the 64 GB. The CPU is the tighter resource. Check with `nproc` and `free -g` on the box before sizing further (MISTAKES.md 2026-11-10).

## Unverified (checked at build, before anything goes live)

- **Tailscale sidecar:** non-root with `read_only`, and whether it serves Services in userspace mode to another container's IP. The containerboot source supports the config; the behaviour hasn't been tested.
- **`read_only`** for cloudflared, paperless-ngx (rootless), FileBrowser Quantum, Kopia, RustFS and all four Immich containers. Every writable path listed comes from reading the code, not from upstream docs.
- **Running as a non-root uid:** Immich Postgres with an arbitrary uid (nss_wrapper), and Kopia as non-root.
- **Image uids:** Filestash's and Dillinger's (not read from the image layers).
- **Capability sets:** Scrutiny's under s6. ArchiveTeam Warrior's per-project needs and target hosts.
- **Time Machine:** its capability set.
- **Networking:** Homey's discovery on a macvlan address, and Komga without egress.
- **MOS (#310 §7b):** macvlan with a VLAN parent, the Docker version, and whether the MOS UI manages stacks started from these files.

## Follow-ups (not built; each its own PR after the OK)

- **Tailscale:** Services and grants per stack as listed above; retire Hawser, `svc:dockhand` and the guests' monitoring grants.
- **Cloudflare:** the tunnel(s), public hostnames and Access policies.
- **`config-files/mos/media-mount.sh`:** restart containers instead of LXCs after a remount.
- **Docs:** CLAUDE.md §8 (host roles, Dockhand-home, host layout), `SECURITY.md`, `security/*.md`.
- **`docker-compose/CONTAINERS.md`:** move the reserved names into the main table when built.
