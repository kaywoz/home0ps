# Proposal: Docker stacks on the replacement storage host

> **Status: proposal — nothing is deployed or built.** kaywoz OKs (or changes) this before anything runs. The three compose files next to this README are drafts that validate (`docker compose config --quiet`), not deploy instructions.

Three separate stacks for MOS on the replacement storage host (the 4-bay NVMe box tested in kaywoz/home0ps#310). Each replaces one of today's guests on the current storage host:

| Stack | File | Replaces | Zone |
|---|---|---|---|
| **media** | [`media/compose.yaml`](media/compose.yaml) | the media LXC | VLAN 13 (IoT) |
| **infra** | [`infra/compose.yaml`](infra/compose.yaml) | the infra VM | VLAN 24 (infra, tier 0) |
| **apps** | [`apps/compose.yaml`](apps/compose.yaml) | the apps VM | VLAN 31 (apps) |

This follows the scenario in kaywoz/home0ps#314: Docker runs **directly on MOS**, one stack per zone, each on a macvlan network on its VLAN sub-interface, **with no host IP on those VLANs**. The MOS UI is the storage host's only management portal (#312). kaywoz asked for the media stack to replace the media LXC and to "do the same" for the infra VM and the apps VM in separate stacks. I read that as all three moving onto the new box. If the infra VM and apps VM are meant to stay as VMs, the infra and apps stacks drop their macvlan and Tailscale-sidecar parts and go back to today's layout (`/srv/docker`, `127.0.0.1` ports, `tailscale serve` on the VM). See open question G1.

## Where the app choice comes from

The candidate discussion was in an earlier session (2026-11-13). It had a long list built from kaywoz's GitHub stars, `kaywoz/mos-templates`, the MOS Hub catalogue (mos-official.net, 438 apps) and generic homeserver apps, then a short list, then a check of that short list against the Hub. This proposal takes the short list and places each app in a zone:

| Short-list app | Where it goes here |
|---|---|
| Jellyfin, Komga, Homey SHS | **media** (already running in the media LXC) |
| Ollama, mediasort | **apps** (already running in the apps VM) |
| paperless-ngx | **apps** |
| one file UI: copyparty (#42) or Filestash (#40) | **apps**: copyparty (see A-Q2) |
| Pocket ID | **infra** |
| cloudflared | **infra** (planned for the infra VM in §8 and #174) |
| git-pull deployer (#314) | **not in a stack**: it deploys the stacks, so it can't live in one (`--remove-orphans` would touch itself). Stays its own entry per #314, pending the socket decision there |
| Kopia (#43), Time Machine, one S3 (#39) | **not in these stacks**: storage services of the storage host itself, deployed from MOS templates like the socket proxy (`config-files/mos/containers.md`). Separate proposal |
| Immich *(optional on the short list)* | **parked**: several containers, heavy on RAM/CPU for a 4-core N95 |

Also from that discussion, and still standing: no Dockge/Portainer/Dockhand on MOS (the MOS UI is the portal), no ntfy/Gotify (Slack), no Plex (Jellyfin), no Vaultwarden (1Password), no AdGuard/Pi-hole on the NAS, monitoring tools stay on the monitoring host, lab tools in the lab.

## Common design (all three stacks)

### Networks and reachability
- **One macvlan per zone** (`media-vlan13`, `infra-vlan24`, `apps-vlan31`) on the VLAN sub-interface, no IP on the host side. Only containers that need **egress** or a **LAN presence** join it. Their traffic leaves through the zone's VLAN, so the UniFi zone rules apply as they do to today's guests.
- **Everything else sits on an `internal: true` bridge per app** (`proxy-<app>`): no egress, no published ports (§8: internal when no egress and no ports). An internal bridge never gets a gateway, so the macvlan is always the default route where a container has both. No `gw_priority` (Engine ≥ 28) needed.
- **No `ports:` anywhere.** Macvlan containers can't be reached from the host (a kernel restriction, per Docker's macvlan docs), so host-side `tailscale serve` to `127.0.0.1` can't work. Port publishing also doesn't work on macvlan or internal networks (moby source).
- **Each zone that has admin UIs gets its own Tailscale sidecar** (`tailscale/tailscale`, userspace networking, no TUN, no `NET_ADMIN`). It joins the zone's macvlan and the internal bridges it serves, and advertises the Tailscale Services from a serve-config file (`TS_SERVE_CONFIG`, `ipn.ServeConfig` JSON with a `Services` key; auto-advertised since containerboot 1.96). It keeps the zone's existing tag (`tag:media`, `tag:docker`), so the policy mostly stays as is.
- **What the macvlan isolation buys:** a container can't reach the MOS host at all: not the MOS UI, not SMB/NFS, and not the rclone remote control that today listens unauthenticated on all interfaces (#316). On a normal bridge it could, through the bridge gateway.
- **What it costs:** on its macvlan IP every listening port of the container is open to that VLAN. Docker filters nothing there. Each such service is listed per stack below.

**Alternatives considered for reaching the containers:**

| Option | Why not (for now) |
|---|---|
| Bridges + `127.0.0.1` ports + host `tailscale serve` (today's pattern) | Egress would leave from the storage host's own VLAN instead of the zone's, and every container could reach the MOS host on the bridge gateway (MOS UI, SMB, the unauthenticated rclone rc in #316). Needs a host firewall first (#219) |
| MOS "Docker Local Host Access" plugin (shim) | Read its source (`ich777/mos-docker-shim`, `functions`): it makes one shim on `eth0`/`br0` only, routes the host's own subnet through it as two hard-coded /25s, and knows no VLAN sub-interfaces. It doesn't reach containers on `<nic>.13/.24/.31` without the host joining those VLANs. #310 §7d still tests it |
| tsdproxy | Needs a network path to every target, so one instance would bridge all three zones. Stable v2 makes a Tailscale node per container, not Services (Services only in the v3 betas). Adds a dashboard, REST API and webhooks |
| DockTail | Native Services and a read-only Docker API (works behind the socket proxy with `POST=0`), but it drives a tailscaled that must reach the container, so it still needs the per-zone sidecar. Its documented sidecar uses `network_mode: host`. Only replaces a few lines of serve config. Parked: revisit if the number of Services grows |

### Container standard (CLAUDE.md §8) and what's different on MOS
- **Applied everywhere** unless a service's table says otherwise: non-root `user:`, `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `pids_limit`, healthcheck where the image has or allows one, secrets as files (600, owned by the service uid), images on `:latest`.
- **No userns-remap assumed.** MOS's Docker isn't remapped today (`uid_map 0 0 4294967295`, #174); #310 §7c tests whether it can be. Without it, `user:` uids are real host uids, and a container running as root (only Homey) is root on the storage host if it escapes. **Distinct uids per service** so one compromised app can't read another's data:

| Range | Stack | uids |
|---|---|---|
| 20xx | media | 2001 Jellyfin, 2002 Komga, 2010 Tailscale sidecar |
| 21xx | apps | 2103 Ollama, 2104 mediasort (both as today), 2105 paperless, 2106 paperless Redis, 2107 copyparty, 2110 Tailscale sidecar |
| 22xx | infra | 2201 Pocket ID, 2202 cloudflared |

- **Paths:** MOS's root filesystem is RAM. All data lives under `${APPDATA}` on the pool (today `…/appdata/<app>/`, `config-files/mos/containers.md`). There's no `/srv/docker`, and no relative `./` paths, so the files work wherever the stack's checkout sits (#314: same path inside and outside the deployer).
- **One file per stack, not one per host.** §8's host layout is one `compose.yaml` per host; three stacks on one host were asked for explicitly, and #314 left "one folder per stack or one file" open. See G2.
- **Monitoring needs nothing new.** One Docker daemon serves all three stacks, so the existing read-only socket proxy (`kr-ccp-socketproxy-0301`, `POST=0`) and the Beszel agent (`kr-ccp-beszelagent-0201`) on the storage host already see every container. Dozzle reads it remotely as today. The per-guest proxies, Hawser agents and native Beszel agents retire with the guests.
- **Logs:** MOS has no journald (Devuan). Container logs stay in Docker's default driver and Dozzle until log shipping is revived (LogTide is benched). See G5.

## Stack 1 — media (VLAN 13), replaces the media LXC

| App | Why | Container |
|---|---|---|
| Jellyfin | film and TV, already running; hardware transcoding on the N95's iGPU | `kr-ccp-jellyfin-0201` |
| Komga | comics and books, already running; one of Komga/Kavita/Stump/Codex, keep the one in use | `kr-ccp-komga-0201` |
| Homey SHS | home automation, already running; the most important data to back up | `kr-ccp-homey-0201` |
| Tailscale sidecar | serves `svc:jellyfin` and `svc:komga` (tag:media) | `kr-ccp-tailscale-0101` |

**What each gives up against the standard:**

| Service | Deviation | Why |
|---|---|---|
| Jellyfin | `/dev/dri/renderD128` + `group_add` render GID | hardware transcoding (Jellyfin's Intel docs: no privileged, no capabilities) |
| Jellyfin | on `media-vlan13` with a fixed IP: **every port open on VLAN 13** (8096, 7359/udp discovery; 8920/1900 only if HTTPS or DLNA are turned on) | Apple TV and other VLAN 13 clients play locally. Today's exception (8096 + 7359 on the LXC's VLAN 13 address) becomes "all of Jellyfin's ports", so keep HTTPS and DLNA off |
| Komga | `/tmp` tmpfs with `exec` | the SQLite JDBC driver loads its native library from `/tmp` (as today) |
| Komga | **no egress** (internal bridge only) | today it has egress "for metadata". Komga reads embedded metadata. To check: if it needs the internet, it joins `media-vlan13` and is then open on VLAN 13 too (M-Q2) |
| Homey | runs as the image's user (**root**), `cap_add` SETUID, SETGID, SYS_CHROOT, CHOWN | tested on the media LXC (2026-11-07). Without userns-remap on MOS, that root is host root if it escapes, where the LXC used to add a mapping layer. The biggest regression in this proposal (M-Q1) |
| Homey | fixed macvlan IP on VLAN 13 instead of `network_mode: host` | host network would be the storage host's own network. Discovery/mDNS should work on the macvlan L2 segment; to verify |
| Homey | no healthcheck | none documented |
| Tailscale sidecar | non-root + `read_only` | **unverified**: the image has no `USER`; userspace mode needs no TUN/caps (containerboot source), writable paths are the state dir and `/tmp` (socket). Fallback: run it as root with `cap_drop: [ALL]` |

**Secrets (kaywoz creates them on the host, never in git):** a tagged, single-use, pre-approved Tailscale auth key for `tag:media` (file, deleted after the node joins). Jellyfin and Komga carry their own logins in their data folders.

**Tailscale follow-ups (own PRs, not built):** `svc:jellyfin` and `svc:komga` already exist with `tag:media` auto-approval. The new sidecar node takes over from the media LXC node. Remove the Hawser grant (`tag:infra` → `tag:media:2376`) and the media LXC's `tag:observed` monitoring grants when the LXC retires. The serve config for the sidecar (`ipn.ServeConfig` JSON) is written and tested at build time.

**Migration from the media LXC:**
1. #310 passes, and kaywoz decides the swap.
2. Before the cut-over, back up `jellyfin/config`, `komga/config` and `homey/` from the LXC (the backup list from 2026-11-13). `jellyfin/cache` is rebuilt, the Hawser token retires.
3. **Re-own** the restored data to the service uids (2001, 2002; Homey's own ids). The LXC's files are owned by mapped uids, and there's no remap on MOS unless §7c says otherwise.
4. **Homey: start fresh and re-pair** if the restored data crashes its Matter daemon (seen 2026-11-07 with an older install). Its Homey cloud backup is the first choice.
5. `media-mount.sh`: replace `LXCS=` with a list of containers to (re)start after the mount. A FUSE remount isn't seen by an already-running container's bind mount, just as with the LXC. Own PR in `config-files/mos/`.
6. Start the stack with the LXC stopped (same VLAN 13 addresses if reused: Jellyfin's fixed IP keeps Apple TV pointing at it).
7. Check: playback with hardware transcoding (Intel GPU top plugin), Homey devices, `svc:jellyfin`/`svc:komga`, Dozzle shows the containers.
8. Keep the LXC (stopped, autostart off) until the stack has run a week, then archive it.

**Open questions — media:**
- **M-Q1:** Homey as root on the storage host without userns-remap. Accept it, wait for #310 §7c (remap), or move Homey to the apps zone / a small separate device? (The board still has #117 "Homey: locate and move to the apps host".)
- **M-Q2:** Does Komga need egress? If yes, it goes on the VLAN 13 macvlan.
- **M-Q3:** Kavita/Audiobookshelf were on the long list; anything to add now, or keep the stack to what runs today?

## Stack 2 — infra (VLAN 24), replaces the infra VM

| App | Why | Container |
|---|---|---|
| Pocket ID | OIDC with passkeys for the home apps (§8 prefers OIDC + MFA). Tier 0 for logins | `kr-ccp-pocketid-0101` |
| cloudflared | the Cloudflare Tunnel for user-facing apps, §8's second access plane; outbound only | `kr-ccp-cloudflared-0101` |

**Not here:** Dockhand-home. In the #314 scenario the MOS UI is the Docker UI and no other home guest is left for it to manage, so §8's Dockhand-home exception retires for home (Dockhand-lab is unaffected). No Tailscale sidecar either: Pocket ID's passkeys are bound to `APP_URL`'s hostname, so a second origin (`svc:pocketid`) wouldn't work for logins. Nothing else in this stack has a UI.

**What each gives up against the standard:**

| Service | Deviation | Why |
|---|---|---|
| Pocket ID | reachable only through the tunnel (user-facing, so Cloudflare, not Tailscale) | it's the login for user-facing apps; `APP_URL` must be HTTPS for passkeys |
| Pocket ID | no egress | no SMTP, no GeoLite download. Login-location lookup and email notifications are off |
| cloudflared | on `infra-vlan24` (egress), so open on VLAN 24 | it has no service port, only metrics, pinned to `127.0.0.1:20241` (container builds otherwise bind `0.0.0.0`) |
| cloudflared | `read_only` | no writable path documented; to verify at build |

Healthchecks: Pocket ID has one built in; cloudflared uses `cloudflared tunnel --metrics 127.0.0.1:20241 ready` (exec form, the image is distroless).

**Secrets:** Pocket ID's encryption key (`ENCRYPTION_KEY_FILE`, ≥ 16 bytes, written with `printf`, because a trailing newline becomes part of the key). The tunnel token (`TUNNEL_TOKEN_FILE`, cloudflared ≥ 2025.4.0; never `TUNNEL_TOKEN`, since env vars are readable through the socket proxy).

**Tailscale / Cloudflare follow-ups (own PRs, not built):**
- Retire `svc:dockhand`, the `tag:infra` → Hawser grant and its tests, and the infra VM's monitoring grants.
- Cloudflare: a tunnel plus public hostnames for Pocket ID and each user-facing app, and Access policies (`iac/cloudflare/`). How the tunnel reaches apps in another zone is I-Q2.

**Migration from the infra VM:** nothing to carry over except Dockhand's data, kept only for rollback (`dockhand/data` incl. `.encryption_key`). Pocket ID and cloudflared are new. Order: the tunnel first (no hostnames), then Pocket ID behind it, then OIDC per app. Retire the infra VM after Dockhand's rollback window.

**Open questions — infra:**
- **I-Q1:** Retire Dockhand-home for home (§8 exception) as #314 proposes? Yes means a CLAUDE.md §8 change in its own PR.
- **I-Q2:** cloudflared → apps in other zones. (a) A UniFi rule VLAN 24 → the app's address on VLAN 31/13, per port. (b) A second cloudflared per stack, on that stack's internal bridges. (c) cloudflared joins the other stacks' internal bridges, which bridges zones and so isn't recommended. My pick: **(b)**. It keeps each zone self-contained and the infra stack only holds the login provider.
- **I-Q3:** Cloudflare Access in front of Pocket ID: none (it is the login, behind its own passkeys), or Access with a different IdP? And should Pocket ID become Access's IdP for the other apps?
- **I-Q4:** Pocket ID is tier 0 for logins. Is it OK for it to sit on the storage host, or does it belong on a device of its own? Under §8 proportionality, the storage host is my pick.

## Stack 3 — apps (VLAN 31), replaces the apps VM

| App | Why | Container |
|---|---|---|
| mediasort | the media classifier (#260), already running; moves unchanged | `kr-ccp-mediasort-0201` |
| Ollama | the local LLM (#261), already running. **Off by default** (compose profile `ollama`): the N95 has 4 cores and the storage role overheated under local inference before (#270); mediasort uses the Claude API | `kr-ccp-ollama-0201` |
| paperless-ngx | scan, OCR and archive documents; SQLite + Redis, no Postgres, no Tika/Gotenberg | `kr-ccp-paperless-0101` + `kr-ccp-paperlessredis-0101` |
| copyparty | files through a browser, plus WebDAV/SFTP, in one container (#42) | `kr-ccp-copyparty-0101` |
| Tailscale sidecar | serves `svc:paperless`, `svc:copyparty` and the mover's `tcp:8089` (tag:docker) | `kr-ccp-tailscale-0201` |

**What each gives up against the standard:**

| Service | Deviation | Why |
|---|---|---|
| mediasort | on `apps-vlan31` (egress to TMDB + the LLM provider): **8089 open on VLAN 31** | was `127.0.0.1` + tailnet only. It's bearer-token protected and only classifies names |
| mediasort | `build:` on the host | it's our own image. A host-side build needs the repo checkout, and #314's deployer option B can't build (A-Q1) |
| Ollama | no egress; models pulled by temporarily connecting it to `apps-vlan31` (`docker network connect`, pull, disconnect) | the API has no authentication, so it never sits on a VLAN |
| Ollama | `cpus: 2` of 4 | the NAS keeps serving while a model runs |
| paperless-ngx | `read_only` with `S6_READ_ONLY_ROOT=1` + tmpfs `/run`, `/tmp`, `/var/cache/fontconfig` | rootless mode (`user:`) is supported upstream; read-only + rootless together isn't tested upstream, so verify at build |
| paperless-ngx | OCR language fixed to the image's built-ins | extra languages are installed at start, which rootless mode can't do |
| paperless Redis | password in a config file (`requirepass`), not a `*_FILE` env | Redis has no `*_FILE` support. The sidecar shares the bridge, so Redis isn't left open. Its healthcheck reads the password from the file; it is visible to processes inside that container |
| copyparty | `read_only` | not documented upstream; config and state in `/cfg`, uploads in `/w`; verify at build |
| copyparty | accounts in a config file in the data folder | no `*_FILE` env; passwords stored argon2-hashed |
| Tailscale sidecar | non-root + `read_only` | **unverified**, as in the media stack |

**Secrets:** a Tailscale auth key for `tag:docker`. mediasort: `token`, `tmdb`, `llm` (as today). paperless: `secret_key`, `redis_url`, and `redis.conf` with the same password. copyparty: account hashes in its config.

**Tailscale follow-ups (own PRs, not built):**
- `iac/tailscale-services/`: add `svc:paperless` and `svc:copyparty`. `iac/tailscale/policy.hujson`: auto-approve both for `tag:docker`, plus a grant per Service to the admins.
- The mover's grant (`tag:storage` → `tag:docker:8089`) and its tests stay; the target becomes the sidecar node. Its `CLASSIFIER_URL` changes to the sidecar's MagicDNS name.
- Retire the Hawser grant to `tag:docker`, the apps VM's monitoring grants and `svc:cockpit-<apps device>`.

**Migration from the apps VM:**
1. Copy `mediasort/secrets/` and, optionally, `ollama/models` to `${APPDATA}`, and **re-own** them from the remapped uids (102103, 102104) to 2103, 2104.
2. Start mediasort, then point the mover at the sidecar (`CLASSIFIER_URL`) and run one dry run.
3. paperless and copyparty are new; nothing to migrate.
4. Retire the apps VM once the mover has run cleanly for a day.

**Open questions — apps:**
- **A-Q1:** mediasort's image: build it on the host (needs the checkout and a build-capable deployer), or a GitHub Actions build to ghcr.io (our own supply chain, flagged in #314)?
- **A-Q2:** copyparty (#42) or Filestash (#40)? copyparty is one container, runs as any uid and also does WebDAV/SFTP. Filestash's binary is mode 730 for its own user, so an arbitrary `user:` can't run it. My pick: **copyparty**. Which folders should it serve (`${SHARES}`)?
- **A-Q3:** paperless: user-facing (Cloudflare Tunnel + Access + OIDC via Pocket ID) or admin-only over Tailscale? How do scans reach `consume/` (copyparty upload, SMB share, scanner email)?
- **A-Q4:** Keep Ollama at all on this box, given #270? It's off by default here.
- **A-Q5:** Immich: parked, or a later proposal?

## General open questions

- **G1:** Do all three stacks run on MOS (my reading of the request, and #314's scenario), or do the infra and apps VMs stay?
- **G2:** One compose file per stack (as here) or one file per host (§8 host layout)? CLAUDE.md §8 and #314 then get updated to match.
- **G3:** §8 calls the storage host "storage only". These stacks make it the home Docker host. That's the #314 scenario, but §8's host roles, `SECURITY.md` and `security/{storage,media,infra,apps}.md` need rewriting in the same change as the build.
- **G4:** Run the stacks before #310 §7b–§7e are done? Their results decide whether MOS's UI manages compose stacks, whether macvlan with a VLAN parent works from MOS, and whether userns-remap is possible. My pick: **no, wait for §7b–§7e**.
- **G5:** Container logs off-box on MOS (no journald). Docker's `syslog` driver to the monitoring host, or wait until log shipping is revived?
- **G6:** The stacks need VLAN 13/24/31 tagged on the storage host's switch port, and a small address block per VLAN outside DHCP for macvlan. Today the guests' VLANs come from PCI passthrough and the LXC's own NIC.

## Unverified (checked at build, before anything goes live)

- Tailscale sidecar as non-root with `read_only`; Services served in userspace mode to another container's IP (containerboot source supports the config, behaviour not tested).
- `read_only` for cloudflared, paperless-ngx (with rootless) and copyparty.
- Homey discovery on a macvlan address; Komga without egress.
- macvlan with a VLAN parent on MOS, and MOS's Docker version (#310 §7b).
- Whether the MOS UI shows and manages stacks started from these files (#310 §7b).

## Follow-ups (not built; each its own PR after the OK)

- Tailscale: Services and grants per stack as listed above; retire Hawser, `svc:dockhand` and the guests' monitoring grants.
- Cloudflare: the tunnel and public hostnames, Access policies.
- `config-files/mos/media-mount.sh`: restart containers instead of LXCs after a remount.
- CLAUDE.md §8 (host roles, Dockhand-home, host layout), `SECURITY.md`, `security/*.md`.
- `docker-compose/CONTAINERS.md`: move the reserved names into the main table when built.
- The storage services (Kopia, Time Machine, S3) as their own proposal.
