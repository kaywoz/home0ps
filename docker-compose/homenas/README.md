# Proposal: Docker stacks on the replacement homenas

> **Status: proposal — nothing is deployed or built.** kaywoz OKs (or changes) this before anything runs. The four compose files next to this README are drafts that validate (`docker compose config --quiet`), not deploy instructions.
>
> **Decided 2026-11-17 (kaywoz):** Docker runs directly on MOS and **all** stacks go there: no LXC and no VM stays. The #310 tests are done; verdict "viable, with conditions". Later the same day the design was cut back to need and proportionality ([Baseline](#baseline)).

| Stack | File | Apps | Replaces |
|---|---|---|---|
| **media** | [`media/compose.yaml`](media/compose.yaml) | Jellyfin, Komga, Homey | the media LXC |
| **infra** | [`infra/compose.yaml`](infra/compose.yaml) | cloudflared, the box's socket proxy and Beszel agent | the infra VM; the proxy and agent move from MOS-template deploys |
| **apps** | [`apps/compose.yaml`](apps/compose.yaml) | mediasort, paperless-ngx, CannonCommander, Immich, ArchiveBox, ArchiveTeam Warrior, Atuin, HedgeDoc, Filestash, RackPeek | the apps VM |
| **storage** | [`storage/compose.yaml`](storage/compose.yaml) | Kopia, Time Machine, RustFS, Scrutiny collector (once a day from MOS cron) | new (#43, #39, #103) |

The MOS UI is the homenas's only management portal and its Docker UI (#312; Dockhand-home retires, I-Q1). The app lineup is kaywoz's (2026-11-16, from his GitHub stars, `kaywoz/mos-templates` and the MOS Hub catalogue). Off the table for now: Pocket ID, Ollama, copyparty, the S3 alternatives to RustFS.

## Baseline

kaywoz, 2026-11-17: "if we simply want to deploy stacks with reasonable defaults which are safe [...] what do we actually need to do". The earlier draft (userns-remap, a macvlan zone per VLAN, per-zone Tailscale sidecars, an infra stack owning every network) cost hours of platform workarounds for little risk reduction (MISTAKES.md, homenas proportionality). The design is now what comparable NAS platforms do, plus the per-container standard:

| | Synology / UGREEN / Unraid / TrueNAS apps | This design |
|---|---|---|
| Docker daemon | as shipped, root, no remap | **as MOS ships it**, no remap, no boot hooks |
| Containers | often root, `PUID`/`PGID` | non-root `user:` where the image allows, `cap_drop: [ALL]`, `no-new-privileges`, memory and pid limits (CLAUDE.md §8) |
| Networks | bridge, ports on the host IP | one bridge per app, **ports on `127.0.0.1`**; macvlan only where layer 2 or isolation is needed |
| Remote access | vendor relay or reverse proxy | **the host's own `tailscale serve`**, one Service per admin UI, grants per Service |

What each dropped layer would have bought, and why it went:

| Dropped | Threat | Already covered by | What it cost |
|---|---|---|---|
| userns-remap | container root escaping to host root | non-root uids, `cap_drop: [ALL]` and `no-new-privileges` on all but four containers (E3–E6); a kernel exploit gets root either way | boot hook + cron guard (MOS keeps `/etc` in RAM), re-owning all appdata to 165536+N, five exemptions, a group bug after a reboot, and Docker found running on RAM after restarts outside MOS (cause not confirmed) |
| macvlan zones + sidecars | containers egressing or reachable on the wrong VLAN | Tailscale grants per Service, the apps' own logins, UniFi (#322) | two sidecars and auth keys, cross-stack networks, a boot-order dependency, no host access to the containers |
| `read_only` at any cost | writes to the image filesystem | non-root already blocks most | per-app workarounds; now: kept where it works, **dropped at build where it doesn't** (no workaround, noted in the stack's table) |

**Where the effort goes instead:** #255 (an offsite copy host root can't delete: the most likely serious loss on a NAS is data and backups wiped together) and #322 (UniFi).

## Common design

### Networks and access
- **Default:** each app gets a plain bridge `proxy-<app>` and publishes its UI on `127.0.0.1`. The host serves it: `tailscale serve --service=svc:<app> http://127.0.0.1:<port>`. Every Service is advertised by the homenas's own node (`tag:storage`). Databases and Redis sit on an internal `<app>-backend` bridge with the app only.
- **Each stack owns its networks.** No `external:` networks, so stacks start in any order.
- **macvlan only where needed**, each owned by the one stack that uses it, no host IP on the VLAN:

  | Network | Stack | Containers | Why |
  |---|---|---|---|
  | `media-vlan13` | media | Jellyfin, Homey | layer 2 on VLAN 13: Apple TV playback and discovery, Homey's device bridging |
  | `apps-vlan31` | apps | ArchiveBox, ArchiveTeam Warrior | they fetch arbitrary URLs: they leave through VLAN 31 under internet-only UniFi rules and can't reach the host directly (A-Q12, G8) |
  | `clients-vlan11` | storage | Time Machine | SMB on 445 next to MOS's own Samba; discovery on the trusted clients' VLAN (S-Q2) |

- **Reaching macvlan containers:** the host can't talk to its own macvlan children directly (a kernel restriction), but it can through the router: the host sends to the container's VLAN address via its gateway, UniFi routes it, and it comes back in tagged on the VLAN. So `svc:jellyfin`, `svc:archivebox` and `svc:archivewarrior` target the containers' VLAN addresses. Needs one UniFi allow rule, the homenas → those addresses and ports (8096, 5797, 8001); #322's block of VLAN → homenas doesn't affect replies. **To verify before the build** (test (d)).
- **What bridges allow:** a container on a plain bridge has egress via the host and can reach the MOS host's own listeners through the bridge gateway. Accepted (S-Q1): every host TCP listener needs a login or is tailnet-only.
- **Considered and not used:** the MOS "Docker Local Host Access" plugin (tested in #310 §7d: one shim on the main interface only, no help for VLAN containers); tsdproxy and DockTail (both still need a path to every container; parked).

### Container standard and MOS specifics
- **Applied everywhere** unless a stack's table says otherwise: non-root `user:`, `read_only` + `tmpfs` where it works, `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `pids_limit`, healthcheck where the image has one, secrets as files (600, owned by the uid in `user:`), images on `:latest` (one exception, E7).
- **No userns-remap** (kaywoz, 2026-11-17). A uid in `user:` is the same uid on the host, so appdata and secret files are owned by it. Distinct uids per service keep one app out of another's data.

  | Range | Stack | uids |
  |---|---|---|
  | 20xx | media | 2001 Jellyfin, 2002 Komga (Homey: root, E3) |
  | 21xx | apps | 2104 mediasort, 2105 paperless, 2106 paperless Redis, 2111 Immich server, 2112 Immich ML, 2113 Immich Postgres, 2114 Immich Valkey, 2121 Atuin, 2123 HedgeDoc; CannonCommander runs as the Samba-only data user (A-Q2) |
  | image uids | apps | ArchiveBox 911, ArchiveTeam Warrior 1000, RackPeek 1654, Filestash its image's own user (unverified, likely 1000: A-Q10) |
  | 22xx | infra | 2201 cloudflared; Beszel agent 65534; socket proxy root (E6) |
  | 23xx | storage | 2301 Kopia, 2302 RustFS, 2303 Time Machine share owner (the process is root, E4) |

- **Paths:** MOS's root filesystem is RAM. All data lives under variables pointing at the pool (`${APPDATA}`, `${PHOTOS}`, `${BACKUPS}`, …); no relative paths.
- **One file per stack** (G2); each folder is one MOS stack.
- **Monitoring:** one read-only socket proxy (`POST=0`) and one Beszel agent see every container. Dozzle reads this host through the proxy (no Dozzle agent: it would need the full socket). The guests' proxies, Hawser agents and native Beszel agents retire with the guests.
- **Logs:** MOS has no journald (Devuan). Container logs go to the monitoring host (G5); Dozzle for live viewing.

### MOS: deploy, restarts, NIC and backups (from #310)

**Deploy procedure:**
1. Put the secret files and data folders on the pool, owned by each service's uid (tables per stack).
2. Per stack, in any order: create the stack in the MOS UI, paste `compose.yaml` and the filled-in `.env` values, turn its **autostart on**, start it.
3. Add the host's `tailscale serve --service=…` lines for the stack's Services.
4. Later changes go through the UI too. MOS keeps two copies of each stack (the boot stick's and appdata's `compose_<stack>/`); an edit on disk leaves the stick copy stale. The repo's file stays the source of truth; what runs is checked against it with a `diff` (CLAUDE.md §2).

**Restarts:** `restart: unless-stopped` alone isn't enough: MOS's stop runs `docker stop`, so stacks come back through **MOS autostart**. Start and restart Docker **only from the MOS UI** (or a reboot): a restart of the init script by hand doesn't bring the stacks back, and Docker isn't guaranteed to come up on MOS's data-root mount (2026-11-17: it ran on RAM after a manual restart).

**NIC watchdog:** every macvlan container (Jellyfin, Homey, the archivers, Time Machine) hangs off the built-in NIC, as does the host's own Tailscale. A receive wedge takes them off the network until the watchdog clears it, about a minute end to end. Whether `<nic>.<vlan>` and the containers recover after the watchdog's down/up is test (b).

**Backups of appdata:** SnapRAID excludes appdata and Docker's folders (live data; #310), so appdata is protected only by the backup chain: MOS Backup plugin → `2.backup` → Kopia → the USB disk and the Storage Box. Restore with `tar --numeric-owner` so files keep their uids. The offsite gap is #255.

## Stack 1 — media, replaces the media LXC

| App | Container | Network | Served as |
|---|---|---|---|
| Jellyfin | `kr-ccp-jellyfin-0201` | `media-vlan13`, fixed address | `svc:jellyfin` → its VLAN 13 address, 8096 |
| Komga | `kr-ccp-komga-0201` | `proxy-komga`, `127.0.0.1:25600` | `svc:komga` |
| Homey SHS | `kr-ccp-homey-0201` | `media-vlan13`, fixed address | its own app/cloud (no Service) |

| Service | Deviation | Why |
|---|---|---|
| Jellyfin | `/dev/dri/renderD128` + `group_add` render GID | hardware transcoding (Jellyfin's Intel docs: no privileged, no capabilities) |
| Jellyfin | every port open on VLAN 13 (8096, 7359/udp; keep HTTPS and DLNA off) | VLAN 13 clients play locally; egress via VLAN 13 |
| Komga | `/tmp` tmpfs with `exec` | the SQLite JDBC driver loads its native library from `/tmp` |
| Komga | plain bridge, egress via the host (M-Q2) | metadata downloads; no layer-2 need |
| Homey | **E3:** root, `read_only`, `no-new-privileges`, `cap_drop: [ALL]` + `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN` | the hardening tested in #229 (core and Matter daemon run as uid 0). Without remap that is host root; on the macvlan it can't reach the host's addresses (M-Q1) |
| Homey | fixed macvlan address instead of `network_mode: host` | host network would be the homenas's own network; mDNS on the macvlan segment to verify |

**Tailscale follow-ups:** `svc:jellyfin` and `svc:komga` exist; their auto-approval moves from `tag:media` to `tag:storage`. Retire the Hawser grant to `tag:media` and the LXC's monitoring grants with the LXC.
**UniFi follow-up:** allow the homenas → Jellyfin's address, tcp:8096 (for `svc:jellyfin`).

**Migration from the media LXC:**
1. Back up `jellyfin/config`, `komga/config`, `homey/` (`jellyfin/cache` is rebuilt).
2. Re-own the restored data to 2001 (Jellyfin) and 2002 (Komga): the LXC's files carry its mapped uids.
3. **Homey: start empty and re-pair** (#229: restored data crashed the Matter daemon); its cloud backup first.
4. `media-mount.sh`: restart these containers instead of the LXC after a remount (own PR).
5. Start the stack with the LXC stopped; reuse Jellyfin's VLAN 13 address so Apple TV keeps pointing at it.
6. Check playback with hardware transcoding, Homey devices, both Services, Dozzle. Keep the LXC stopped for a week, then archive it.

## Stack 2 — infra, replaces the infra VM

| App | Container | Network | Serves |
|---|---|---|---|
| cloudflared | `kr-ccp-cloudflared-0101` | own bridge, egress only | the Cloudflare Tunnel for user-facing apps (§8's second access plane) |
| socket proxy | `kr-ccp-socketproxy-0301` | bridge, `127.0.0.1:2375` | read-only Docker API for Dozzle and the Beszel agent (`tailscale serve --tcp=2375`, tag:monitoring only) |
| Beszel agent | `kr-ccp-beszelagent-0201` | host network | host metrics and container stats, `LISTEN` on the tailnet IP only |

| Service | Deviation | Why |
|---|---|---|
| cloudflared | metrics pinned to `127.0.0.1:20241` | container builds otherwise bind `0.0.0.0` |
| socket proxy | **E6:** root, no `cap_drop` | it opens `docker.sock`; `POST=0` is the control, as today |
| Beszel agent | `network_mode: host` | upstream requirement for interface stats; key and token as files |

**Secrets:** the tunnel token as a file (`TUNNEL_TOKEN_FILE`; never `TUNNEL_TOKEN`, env vars are readable through the socket proxy); the Beszel `key` and `token` (owned 65534).

**Decisions** (kaywoz, 2026-11-17):
- **I-Q1:** Dockhand-home retires for home; the MOS UI is the home Docker UI. Dockhand-lab is unaffected.
- **I-Q2:** a public app is reached by cloudflared joining that app's `proxy-<app>` network. Jellyfin, if ever public: a UniFi rule from cloudflared's egress to Jellyfin's address, 8096 only.
- **I-Q3 — open (tbd):** no app is public yet; cloudflared joins no app network until one is picked.
- **I-Q4 — superseded by the baseline:** no sidecars; the host serves every Service.

**Tailscale follow-ups:** the socket proxy's serve and grant stay. Retire `svc:dockhand`, the Hawser grants and tests, and the infra VM's monitoring grants. **Cloudflare:** tunnel, hostnames and Access policies once I-Q3 is decided.

**Migration:** remove the MOS-template socket proxy and Beszel agent, then start the stack (same names, same data folder; the agent needs its key and token as files first). Keep Dockhand's data for rollback only; retire the infra VM after the rollback window.

## Stack 3 — apps, replaces the apps VM

| App | Container | Network / port | Served as |
|---|---|---|---|
| mediasort | `kr-ccp-mediasort-0201` | `127.0.0.1:8089` | the mover on this host calls it directly; no Service |
| paperless-ngx | `kr-ccp-paperless-0101` + `-paperlessredis-0101` | `127.0.0.1:8000` | `svc:paperless` |
| CannonCommander | `kr-ccp-cannoncommander-0101` | `127.0.0.1:8080` | `svc:cannoncommander` |
| Immich | `kr-ccp-immich-0101`, `-immichml-0101`, `-immichdb-0101`, `-immichredis-0101` | `127.0.0.1:2283` | `svc:immich` |
| ArchiveBox | `kr-ccp-archivebox-0101` | `apps-vlan31`, fixed address | `svc:archivebox` → its VLAN 31 address, 5797 |
| ArchiveTeam Warrior | `kr-ccp-archivewarrior-0101` | `apps-vlan31`, fixed address | `svc:archivewarrior` → its VLAN 31 address, 8001 |
| Atuin | `kr-ccp-atuin-0101` | `127.0.0.1:8888` | `svc:atuin` |
| HedgeDoc | `kr-ccp-hedgedoc-0101` | `127.0.0.1:3000` | `svc:hedgedoc` |
| Filestash | `kr-ccp-filestash-0101` | `127.0.0.1:8334` | `svc:filestash` |
| RackPeek | `kr-ccp-rackpeek-0101` | `127.0.0.1:8081` | `svc:rackpeek` |

| Service | Deviation | Why |
|---|---|---|
| mediasort | prebuilt `ghcr.io/kaywoz/mediasort:latest` | built in GitHub Actions (A-Q1) |
| paperless-ngx | `read_only` via `S6_READ_ONLY_ROOT=1`; OCR languages limited to the built-ins | rootless mode can't install languages at start |
| Redis / Valkey | password in a config file | no `*_FILE` support; the healthcheck reads the file at run time |
| CannonCommander | entrypoint bypassed (`tini -- /app/cannoncommander`), `user: "${SHARE_UID}:${SHARE_GID}"`, admin password in `config.yaml` (600), port 8080 | the entrypoint needs root; a fresh install opens without a sign-in until a password is set; it writes the same files as SMB (A-Q2). No FUSE, `SYS_ADMIN` or `DAC_*` from upstream's template: rclone remotes, terminal, MCP server and WebDAV stay off |
| Immich server/ML | tag `release` | Immich publishes no `latest` |
| Immich Postgres | **E7:** a version tag | no moving tag; follows the release compose (A-Q5) |
| Immich ML | profile `immich-ml`, off (A-Q4) | the 8 GB box can't spare it; if enabled, egress via its own bridge, API unpublished |
| ArchiveBox | **E1:** uid 911, not `read_only`; admin by a one-off `createsuperuser` | `/opt/archivebox` holds the browser and plugin binaries; no `*_FILE` support |
| ArchiveTeam Warrior | **E2:** uid 1000, not `read_only`; `http_password` in a pre-made `projects/config.json` (600) | `/home/warrior/data` holds its `wget-at` binaries; the UI has no login without it |
| Atuin | `:latest`, SQLite | upstream's `latest` lags (A-Q8) |
| HedgeDoc | SQLite; session secret as the Docker secret `sessionsecret`; `latest` = 1.12.0 | HedgeDoc reads secrets by name; upstream withdrew 1.12.1/1.12.2 |
| Filestash | image's own user, no `user:` | its binary is mode 730; `/admin/setup` is open until an admin password is set: set it right after the first start |
| RackPeek | uid 1654; **no authentication on its UI** | admins only, by grant (A-Q11) |

**Secrets:** mediasort `token`, `tmdb`, `llm`; paperless `secret_key`, `redis_url`, `redis.conf`; CannonCommander `config.yaml`; Immich `db_password` (two copies, one per uid), `redis_password`, `valkey.conf`; HedgeDoc `session_secret`; Warrior `projects/config.json`; Filestash's admin hash in its `config.json`; ArchiveBox's superuser in its database.

**Tailscale follow-ups:** add `svc:paperless`, `svc:cannoncommander`, `svc:immich`, `svc:atuin`, `svc:hedgedoc`, `svc:filestash`, `svc:rackpeek`, auto-approved for `tag:storage`, a grant per Service (Atuin: every syncing machine). `svc:archivebox` and `svc:archivewarrior` already auto-approve `tag:storage`. Retire the mover's grant to `tag:docker:8089` (the mover is local now), the Hawser grant, the apps VM's monitoring grants and its Cockpit Service.
**UniFi follow-ups:** internet-only rules for both archiver addresses (block RFC1918 and the other VLANs); allow the homenas → them on 5797 and 8001; **device isolation on VLAN 31** (G9).

**Migration from the apps VM:** copy `mediasort/secrets/`, re-own to 2104, set the mover's `CLASSIFIER_URL=http://127.0.0.1:8089`, run one dry run. Immich imports existing photos as an external library (A-Q3). Retire the VM once the mover has run cleanly for a day.

**Decisions** (kaywoz, 2026-11-17):
- **A-Q1:** mediasort built in GitHub Actions and pushed to ghcr.io; the workflow is its own PR.
- **A-Q2:** CannonCommander serves `1.data` and `tmp` only (`${SHARE_DATA}`, `${SHARE_TMP}`, under `/mnt/user`), local accounts. It runs as the **Samba-only data user** that owns both folders and that the MOS SMB shares use, so SMB and CannonCommander write as the same owner. Done on the host: both folders owned by that user and MOS's `mos` group, 755. To verify at build: it starts with the entrypoint bypassed and `read_only`; fallback is the image's root entrypoint dropping to the data user (E8).
- **A-Q3:** existing photos as a read-only external library (`${PHOTOS_LIBRARY}:/external:ro`), readable by uid 2111.
- **A-Q4:** Immich ML off. **A-Q5:** the Postgres version tag accepted. **A-Q6:** upload through paperless's UI or app. **A-Q8:** Atuin on `:latest`. **A-Q9:** HedgeDoc 1.x. **A-Q10:** both file managers; at build check Filestash's uid against the Warrior's 1000. **A-Q11:** no tinyauth; RackPeek and the Warrior limited by grant.
- **A-Q12:** the archivers on VLAN 31 with internet-only UniFi rules; revisit once the lab is built.

## Stack 4 — storage

| App | Container | Network / port | Served as |
|---|---|---|---|
| Kopia | `kr-ccp-kopia-0101` | `127.0.0.1:51515` | `svc:kopia` (`https+insecure://`) |
| Time Machine | `kr-ccp-timemachine-0101` | `clients-vlan11`, fixed address | SMB on VLAN 11 (no Service) |
| RustFS | `kr-ccp-rustfs-0101` | `127.0.0.1:9000` (S3), `:9001` (console) | `svc:s3`, `svc:rustfs` |
| Scrutiny collector | `kr-ccp-scrutinycollector-0101` | own bridge, egress only | pushes to `svc:scrutiny` on the monitoring host |

| Service | Deviation | Why |
|---|---|---|
| Kopia | TLS with its own certificate; UI login from an htpasswd file; repository password persisted by Kopia (600) | the repository server's gRPC needs TLS; no password on the command line or in env |
| Time Machine | **E4:** root, not `read_only`, six capabilities (CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, NET_BIND_SERVICE) | its entrypoint writes users and the Samba config into `/etc`; each capability confirmed at build |
| Time Machine | macvlan on VLAN 11 | MOS's own Samba holds 445 on the host |
| RustFS | keys as files; console CORS limited to its Service URL | never the default `rustfsadmin`; the image defaults CORS to `*` |
| Scrutiny collector | **E5:** root, `SYS_RAWIO` + `SYS_ADMIN`, the NVMe controller devices only, `read_only`, profile `cron` | NVMe SMART needs them; collector only, runs seconds a day from MOS cron |

**Secrets:** Kopia's repository password (stored by Kopia), `htpasswd`, TLS key and certificate; Time Machine `password` (root, 600); RustFS `access_key`, `secret_key`.

**Tailscale follow-ups:** add `svc:s3` (S-Q3), auto-approved for `tag:storage`, admins first, then per client host (#28). Grants per backup client to `svc:kopia`. `svc:scrutiny` on the monitoring host plus one push grant `tag:storage` → `svc:scrutiny`: a new push flow outside §8's list, so it needs kaywoz's OK.
**UniFi follow-ups:** VLAN 13 → Time Machine's address, tcp:445 only; mDNS on for VLANs 11 and 13 if Macs on VLAN 13 should discover it.

**Migration:** Kopia and RustFS are new here (a MOS-template RustFS, if any, is migrated or retired separately). Mac backups start fresh, or are copied with the share's owner changed to 2303.

**Decisions** (kaywoz, 2026-11-17):
- **S-Q1:** containers on plain bridges reaching the host's listeners is accepted; MOS ships no firewall tooling. Condition: NFS exports, if enabled, never cover `*` or a Docker subnet. A MOS firewall plugin is parked (#339).
- **S-Q2:** Time Machine in a container on a VLAN 11 macvlan, not MOS's Samba (its `smb.conf` is in RAM `/etc`).
- **S-Q3:** the S3 API becomes `svc:s3`.
- **S-Q4:** Scrutiny as a collector-only container from MOS UI cron, pushing to the hub on the monitoring host.

## Exception register

Named exceptions to the container standard (CLAUDE.md §8). Without remap, container root is host root, so E3–E6 are the containers that matter most if one is compromised.

| # | Service | Exception | Contained by |
|---|---|---|---|
| E1 | ArchiveBox | not `read_only`; image uid 911 | non-root, `cap_drop: [ALL]`, VLAN 31 macvlan with internet-only rules |
| E2 | ArchiveTeam Warrior | not `read_only`; image uid 1000; UI login only with `http_password` | as E1; `no-new-privileges` also blocks its passwordless `sudo` |
| E3 | Homey | root, four capabilities | tested in #229; no `privileged`; VLAN 13 macvlan, no path to the host's addresses |
| E4 | Time Machine | root, not `read_only`, six capabilities | no `privileged`; VLAN 11 macvlan, no path to the host's addresses |
| E5 | Scrutiny collector | root, `SYS_RAWIO` + `SYS_ADMIN`, NVMe controller devices | collector only, controller devices only (no namespaces), runs seconds a day |
| E6 | socket proxy | root | `POST=0`, `read_only`, `127.0.0.1` + tailnet (tag:monitoring) only |
| E7 | Immich Postgres | a version tag | no moving tag exists (A-Q5) |
| (E8) | CannonCommander | only if the bypassed entrypoint fails at build: root entrypoint dropping to the data user | see A-Q2 |

**Further mitigations for E1 and E2**, when built: Beszel alerts on sustained CPU/network spikes, Diun (#101) and Trivy (#102) for the two images, IDS/IPS on VLAN 31 if the gateway allows it (#202). Not proposed: Falco or Tetragon (privileged eBPF agents; proportionality).

## General decisions

- **G1:** all stacks on MOS; no LXC and no VM stays.
- **G2:** one compose file per stack, one MOS stack per folder (CLAUDE.md §8's homenas exception).
- **G3:** the role is **homenas**; the Tailscale tag stays `tag:storage`.
- **G5:** container logs go to the monitoring host; driver chosen with its revival (#225).
- **G6:** VLANs 11, 13 and 31 tagged on the homenas's switch port, each with an address block outside DHCP for the macvlans.
- **G7 — 8 GB of RAM.** Sum of `mem_limit`s: media 2.8 GB, infra 0.3 GB, apps 5.4 GB (Immich ML off), storage 1.3 GB, ≈ 9.8 GB of caps before MOS itself. Caps over physical RAM are fine while peaks don't line up (Jellyfin transcoding, paperless OCR, ArchiveBox's Chromium, Immich imports). Watch Beszel the first weeks; next cuts are the archivers (start on demand), then Filestash.
- **G8 — egress** (narrowed 2026-11-17): containers get egress through their bridge via the host; only the archivers leave through VLAN 31 (macvlan), and Jellyfin and Homey through VLAN 13 as its members. VLAN 24 isn't used by Docker.
- **G9 — device isolation on VLAN 31** (kaywoz, 2026-11-18): VLAN 31 also holds containers from other hosts, so UniFi's device isolation is on for that network: VLAN 31 clients can't reach each other through the switch, only the gateway (internet, and routed traffic such as the macvlan Services' path from the homenas). Services that need to talk across hosts do it over Tailscale with a grant. It doesn't cover macvlan containers on the same host (the kernel switches those internally); on the homenas that is only the two archivers. To verify after enabling: test (d) still answers.

## Before the build

Tests on the new box, each with throwaway containers. The remap hook was uninstalled and the remapped store removed on 2026-11-18.

- **(b) NIC watchdog bounce.** With macvlan containers running, bounce the built-in NIC as the watchdog does. Do `<nic>.<vlan>` and the containers recover, or does the watchdog need a hook that restarts them?
- **(c) NIC name.** The built-in NIC is `eth0` only while the USB adapter is unplugged; every `parent: <nic>.<vlan>` depends on it. Leave the adapter out, or pin the name.
- **(d) Host → macvlan via the router — passed** (2026-11-18): with UniFi's allow policy (the homenas → the VLAN 31 block, TCP 5797/8001) and device isolation on, the host got HTTP 200 from a test container on VLAN 31. Without the policy the zone's default block drops it. Jellyfin's policy (TCP 8096) is checked when Jellyfin runs.
- **(e) Docker stays on disk — passed** (2026-11-18): after a reboot with Docker started only by MOS, the data root is `/var/lib/docker` on the pool, unremapped, no `daemon.json`, no pre-start script.

## Go-live prerequisites

Not in these files; each closed before the stacks hold real data:

- **#322 — UniFi:** block VLANs 13, 24 and 31 → the homenas's own address; the archivers' internet-only rules; device isolation on VLAN 31 (G9); the allow rules for the macvlan Services above.
- **#255 — an offsite copy host root can't delete** (Storage Box snapshots or an append-only receiver).

## Unverified (checked at build)

- `read_only` for cloudflared, paperless-ngx, CannonCommander, Kopia, RustFS, HedgeDoc, Filestash and the Immich containers. **Where it fails, drop it** and note it in the stack's table.
- Non-root: Immich Postgres with an arbitrary uid, Kopia.
- Image uids and ports: Filestash's uid, RackPeek's container port.
- Capability sets: Time Machine; ArchiveTeam Warrior per project.
- Homey's discovery on a macvlan address.
- Whether the containers' uids can read the host's rclone media mount (FUSE `allow_other`).
- MOS stack copies: which one MOS uses if appdata is missing, and whether a UI save overwrites a disk edit.

## Follow-ups (not built; each its own PR after the OK)

- **Tailscale:** Services, auto-approvers and grants per stack as listed; retire `tag:media`/`tag:docker` with the guests, Hawser, `svc:dockhand`.
- **UniFi** (#322): the rules listed per stack.
- **Cloudflare:** tunnel, hostnames and Access policies (I-Q3).
- **`config-files/mos/media-mount.sh`:** restart containers instead of the LXC after a remount.
- **`docker-compose/CONTAINERS.md`:** move the reserved names into the main table when built.
- **mediasort image workflow** (A-Q1).
- **Scrutiny hub** on the monitoring host (#103).
