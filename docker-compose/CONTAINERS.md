# Container register

Every container on the home0ps hosts, so names stay unique. Scheme: [`NAMING.md`](../NAMING.md) — `<site>-<type><platform><env>-<service>-<GGMM>`, GGMM = **group, then member**: a separate instance of a service is the next group (`0101`, `0201`, `0301`, …), members of an HA pair share a group (`0401` + `0402`).

**Adding a container:** take the next free group for its service here (or the next member, for an HA pair), use it in the compose/deploy settings, and add the row in the same change. Hosts by role only (real device names never in git).

**Groups by host and stack** (kaywoz, 2026-11-26; no LXCs or VMs remain):

- **homenas** (MOS): stacks infra, apps, media and storage, all group `01`.
- **Monitoring host**: stacks infra and monitoring. The infra stack's services also run on the homenas, so they continue at group `02`, then `03` for a further host. Monitoring-stack services exist only here and are group `01`.

Names stay unique across hosts. Retired hosts' names are in [`archive/docker-compose/CONTAINERS-retired.md`](../archive/docker-compose/CONTAINERS-retired.md).

## homenas (MOS) — built

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-arcane-0101` | homenas (MOS), infra stack | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) | |
| `kr-ccp-cloudflared-0101` | homenas (MOS), infra stack | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) | |
| `kr-ccp-kopia-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |
| `kr-ccp-timemachine-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |
| `kr-ccp-rustfs-0101` | homenas (MOS), storage stack | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) | |
| `kr-ccp-mediasort-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |
| `kr-ccp-cannoncommander-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |
| `kr-ccp-atuin-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |
| `kr-ccp-hedgedoc-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |
| `kr-ccp-filestash-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |
| `kr-ccp-rackpeek-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) | 2026-11-19 |

## homenas (MOS) — reserved, not deployed yet

Names reserved by the homenas stacks ([`homenas/README.md`](homenas/README.md)). They move into the table above when built.

| Container | Host role | Defined in |
|---|---|---|
| `kr-ccp-jellyfin-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-komga-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-homey-0101` | homenas (MOS), media stack | [`homenas/media/compose.yaml`](homenas/media/compose.yaml) |
| `kr-ccp-paperless-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-paperlessredis-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immich-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichml-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichdb-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-immichredis-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-archivebox-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-archivewarrior-0101` | homenas (MOS), apps stack | [`homenas/apps/compose.yaml`](homenas/apps/compose.yaml) |
| `kr-ccp-scrutinycollector-0101` | homenas (MOS), storage stack (run from MOS cron) | [`homenas/storage/compose.yaml`](homenas/storage/compose.yaml) |
| `kr-ccp-socketproxy-0101` | homenas (MOS), infra stack (profile `monitoring`, off) | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) |
| `kr-ccp-beszelagent-0101` | homenas (MOS), infra stack (profile `monitoring`, off) | [`homenas/infra/compose.yaml`](homenas/infra/compose.yaml) |

## Monitoring host — built

Intel N305, Ubuntu ([`../security/monitoring.md`](../security/monitoring.md)). All six are in one compose file today; the split into an infra and a monitoring stack is not built yet.

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-gatus-0101` | monitoring host, monitoring services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
| `kr-ccp-beszel-0101` | monitoring host, monitoring services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
| `kr-ccp-beszelagent-0201` | monitoring host, infra services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
| `kr-ccp-dozzle-0101` | monitoring host, monitoring services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
| `kr-ccp-socketproxy-0201` | monitoring host, infra services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
| `kr-ccp-healthchecks-0101` | monitoring host, monitoring services | [`monitoring/compose.yaml`](monitoring/compose.yaml) | 2026-11-26 |
