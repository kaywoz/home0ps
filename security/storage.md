# Storage host security design

MOS NAS (Devuan-based, RAM root filesystem; persistent config under `/boot/config`, which is mounted non-executable). **Storage only**: holds the data pools, pulls backups, hosts the media LXC. Builds on the [global baseline](../SECURITY.md); this file lists only what is specific to this role.

Containers are deployed from [MOS templates](https://github.com/kaywoz/mos-templates) (generic, upstream defaults); the hardening and addresses added at deploy time are recorded in [`config-files/mos/containers.md`](../config-files/mos/containers.md). Onboarding to Dozzle/Beszel: [`docker-compose/monitoring/observed-hosts.md`](../docker-compose/monitoring/observed-hosts.md). Build-out: kaywoz/home0ps#174, monitoring kaywoz/home0ps#138.

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host; *(unverified)* items haven't been checked on the host at all.

## Network exposure

| Risk | Control |
|---|---|
| Over-broad tailnet access | `tag:storage` + `tag:observed` + `tag:ssh`. Inbound from the tailnet: privusers and the Mac mini reach everything (`*`, admins of this host); lab hypervisors only NFSv4 `tcp:2049` (ISO export, the only lab → home path); the monitoring host tcp:45876 (Beszel agent) and tcp:2375 (read-only socket proxy). The old home automation `tcp:*` grant and its tag were removed (kaywoz/home0ps#233) |
| Docker API exposure | `docker-socket-proxy` (`CONTAINERS`, `INFO`, `EVENTS`; `POST=0`) on **bridge**, published on `127.0.0.1:2375` only, exposed on the tailnet address via `tailscale serve --tcp=2375`. Never host networking: the proxy listens on all interfaces of its namespace. Read from the monitoring host and locally (`_ping` OK, Dozzle shows the host, 2026-11-08); write refused (`POST`→403) and LAN refused *(untested)* |
| Beszel agent listening | Host networking (upstream requirement for interface stats), `LISTEN` bound to the tailnet IP only, so not on the LAN; pushes to `svc:beszel` (verified in the hub, 2026-11-08) |
| Media library exposure | rclone crypt mount is read-only and bound read-only into the media LXC (`config-files/mos/media-mount.sh`, kaywoz/home0ps#197) |
| Host firewall | None yet; the ACL and loopback bindings are the controls *(planned, kaywoz/home0ps#219)* |

## Authentication

| Risk | Control |
|---|---|
| SSH access | `tag:ssh` is set; Tailscale SSH per the global baseline (privusers, admin account, 24h check, never root) *(unverified on this host: `tailscale debug prefs`, sshd config)* |
| MOS web UI | MOS's own login *(unverified: reachability and auth not reviewed)* |

## Containment

| Risk | Control |
|---|---|
| Docker control via monitoring tools | Only the socket proxy mounts `docker.sock`; the Beszel agent reads Docker through it (`DOCKER_HOST=tcp://127.0.0.1:2375`), Dozzle reads it remotely; `POST=0` |
| Container compromise | Socket proxy: `--read-only`, tmpfs `/run` + `/tmp`, `no-new-privileges`, 64 MB, 100 pids. Beszel agent: uid 65534, `--read-only`, `--cap-drop ALL`, `no-new-privileges`, 128 MB, 50 pids. `userns-remap` on MOS's Docker *(unverified)* |
| LXC guest → host | Unprivileged LXCs (root = uid 100000 on the host; MOS has no `newuidmap`, LXC writes the maps itself), device allowlist before the `common.conf` include, GPU group mapped 1:1 only where passed (`config-files/mos/create-lxc.sh`) |
| LXC filling the pool | No disk limit yet (btrfs simple quota idea parked in kaywoz/home0ps#174) |
| Central Docker management | None: no Hawser agent here, Dockhand-home doesn't manage this host's Docker (kaywoz, 2026-11-09). Containers are managed in MOS |

## Secrets

| Risk | Control |
|---|---|
| Cloud credentials | One rclone config for all remotes (`filen`, `filen-crypt`, `putio`): `/boot/optional/plugins/rclone/rclone.conf` (MOS rclone plugin), only on the host, never in git or in the LXC; mode `600`, owner root (verified 2026-11-09). `media-mount.env` host-local *(mode unverified)* |
| Beszel key/token | Set at deploy time in the MOS template, never in git |
| put.io remote (rclone) | Own put.io OAuth app (not rclone's shared client ID); client secret and token only in the host's rclone config `/boot/optional/plugins/rclone/rclone.conf` (the shared config above; never in git or chat). put.io tokens don't expire: revoke the app's authorization in put.io if one leaks, then `rclone authorize` again. Headless setup: `rclone authorize "putio" <client_id> <client_secret>` on a machine with a browser, token pasted on the host only (2026-11-09). A token exposed during setup was revoked *(unverified)* |

## Detection

| Risk | Control |
|---|---|
| Silent host failure | Beszel agent (push, SSH pull fallback on the tailnet IP) |
| Container logs | Visible in Dozzle via the socket proxy (read-only, live only) |
| Media mover (`media-sort.py`) | Hourly cron on this host (#260): asks the classifier on the apps VM (names only, bearer token from `/boot/config/home0ps/media-sort.token`, 600) and `rclone moveto`s each new download into a library. Credentials never leave this host. **No delete against libraries:** no `sync`/`purge`/`delete` on library folders; existing targets are never overwritten (collisions and duplicates are parked in a dated holding folder **on the download remote**, `<download-remote>:_sort/dupes/YYYY-MM-DD/`, by a server-side move, so they are never transferred). Junk-file cleanup (`._*`, `.DS_Store`, `Thumbs.db`) and removal of dated holding folders older than 30 days run daily. Every job is a dry run until its `RUN_*` switch is set; Ctrl-C/kill stops rclone cleanly, and a move cut short is recorded (`/boot/config/home0ps/media-sort.inprogress`) and finished by the next run, so no item is left split; log in `/var/log/media-sort.log` (visible in the MOS UI; RAM, so capped at 2 MB by the script and lost on reboot); ping to the home0ps Healthchecks (`svc:healthchecks`, not the cloud service) with the run summary; daily Slack digest of the last 24 h via an incoming webhook whose URL is a secret file (`/boot/config/home0ps/media-sort.slack`, 600, root; anyone with the URL can post to that channel) *(untested on host)* |
| Media mount failure | `media-mount.sh` cron watchdog every 5 minutes; heartbeat to Healthchecks *(planned, kaywoz/home0ps#225)* |
| Host logs off-box | Not shipped to the log pipeline yet *(planned)* |

## Accepted risks (this role)

- Admins' devices (privusers, the Mac mini) can also read the socket proxy on 2375, unlike on the other hosts: they have `*` to `tag:storage` anyway.
- Container env vars are readable through the socket proxy (`CONTAINERS=1`).
- `LISTEN` on the tailnet IP: the Beszel agent fails to start until Tailscale is up after boot and retries via its restart policy.

## Open issues

- Host firewall, Tailscale SSH as the only SSH path — kaywoz/home0ps#219
- Healthchecks register incl. the media mount watchdog — kaywoz/home0ps#225
- Storage host app UIs (`svc:archivebox`, `svc:archivewarrior`, `svc:scrutiny`, `svc:kopia`, `svc:rustfs`) are defined in the policy and `iac/tailscale-services/` but not served on the host (2026-11-07): planned or stale — to decide
- Separate cloud account for the media library — kaywoz/home0ps#197
- Review: sshd/Tailscale SSH state, MOS UI exposure, Docker `userns-remap`, update mechanism
