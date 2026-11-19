# Container register

Every container on the home0ps hosts, so names stay unique. Scheme: [`NAMING.md`](../NAMING.md) — `<site>-<type><platform><env>-<service>-<GGMM>`, GGMM = **group, then member**: a separate instance of a service is the next group (`0101`, `0201`, `0301`, …), members of an HA pair share a group (`0401` + `0402`).

**Adding a container:** take the next free group for its service here (or the next member, for an HA pair), use it in the compose/deploy settings, and add the row in the same change. Hosts by role only (real device names never in git).

**The homenas is the first host of the current layout (kaywoz, 2026-11-19), so every container on it is group `01`.** The next host to get containers (the monitoring host, rebuilt) takes the next free group per service in the tables below. Names of earlier hosts are listed apart; they're free again once their host is gone.

## homenas (MOS) — built

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-arcane-0101` | homenas (MOS), infra stack | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) | |
| `kr-ccp-cloudflared-0101` | homenas (MOS), infra stack | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) | |
| `kr-ccp-kopia-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |
| `kr-ccp-timemachine-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |
| `kr-ccp-rustfs-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |

## homenas (MOS) — reserved, not deployed yet

Names reserved by the homenas stacks ([`homenas/README.md`](homenas/README.md)). They move into the table above when built.

| Container | Host role | Defined in |
|---|---|---|
| `kr-ccp-jellyfin-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-komga-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-homey-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-mediasort-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-paperless-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-paperlessredis-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-cannoncommander-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immich-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichml-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichdb-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichredis-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-archivebox-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-archivewarrior-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-atuin-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-hedgedoc-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-filestash-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-rackpeek-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-scrutinycollector-0101` | homenas (MOS), storage stack (run from MOS cron) | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) |
| `kr-ccp-socketproxy-0101` | homenas (MOS), infra stack (profile `monitoring`, off) | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) |
| `kr-ccp-beszelagent-0101` | homenas (MOS), infra stack (profile `monitoring`, off) | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) |

## Earlier hosts (before the homenas layout)

The Pi monitoring host, the infra VM, the apps VM and the media LXC, and the MOS-template containers on the old storage box. These hosts are retired or being retired (#320); their names are free again once the host is gone.

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-gatus-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszel-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszelagent-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszelagent-0201` | old storage box (MOS templates) | [`config-files/mos/containers.md`](../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-dockhand-0101` | infra VM | [`infra/compose.yaml`](infra/compose.yaml) | 2026-11-08 |
| `kr-ccp-dozzle-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-hawser-0101` | apps VM | [`apps/compose.yaml`](apps/compose.yaml) | 2026-11-09 |
| `kr-ccp-hawser-0201` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-09 |
| `kr-ccp-socketproxy-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-socketproxy-0201` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-socketproxy-0301` | old storage box (MOS templates) | [`config-files/mos/containers.md`](../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-socketproxy-0401` | infra VM | [`infra/compose.yaml`](infra/compose.yaml) | 2026-11-08 |
| `kr-ccp-socketproxy-0501` | apps VM | [`apps/compose.yaml`](apps/compose.yaml) | 2026-11-08 |
| `kr-ccp-logtidedb-0101` | monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](../archive/docker-compose/logtide/compose.yaml) | |
| `kr-ccp-logtideredis-0101` | monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](../archive/docker-compose/logtide/compose.yaml) | |
| `kr-ccp-logtideapi-0101` | monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](../archive/docker-compose/logtide/compose.yaml) | |
| `kr-ccp-logtideworker-0101` | monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](../archive/docker-compose/logtide/compose.yaml) | |
| `kr-ccp-logtideui-0101` | monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](../archive/docker-compose/logtide/compose.yaml) | |
| `kr-ccp-healthchecks-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-jellyfin-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-mediasort-0101` | apps VM | [`apps/compose.yaml`](apps/compose.yaml) | 2026-11-10 |
| `kr-ccp-ollama-0101` | apps VM | [`apps/compose.yaml`](apps/compose.yaml) | 2026-11-10 |
| `kr-ccp-komga-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-homey-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |

Not containers: the Beszel agent on the infra VM and the apps VM runs natively (systemd), so it has no container name.

LXC guests (`kr-cxp-…`): `kr-cxp-media-0101` (homenas).

Not registered yet: anything started by hand outside these files (check `docker ps` on each host).
