# Retired container names

Moved from `docker-compose/CONTAINERS.md` on 2026-11-26 (kaywoz): the Pi monitoring host, the infra and apps VMs, the media LXC and the old storage box's MOS templates are gone. There are no LXCs or VMs in home0ps any more. These names are free again; links point to where the definitions lived.

## Table as it was

The Pi monitoring host (retired 2026-11-26), the infra VM, the apps VM and the media LXC, and the MOS-template containers on the old storage box. These hosts are retired or being retired (#320); their names are free again once the host is gone.

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-beszelagent-0201` | old storage box (MOS templates) | [`config-files/mos/containers.md`](../../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-dockhand-0101` | infra VM | [`infra/compose.yaml`](../../docker-compose/infra/compose.yaml) | 2026-11-08 |
| `kr-ccp-hawser-0101` | apps VM | [`apps/compose.yaml`](../../docker-compose/apps/compose.yaml) | 2026-11-09 |
| `kr-ccp-hawser-0201` | media LXC | [`media/compose.yaml`](../../docker-compose/media/compose.yaml) | 2026-11-09 |
| `kr-ccp-socketproxy-0201` | media LXC | [`media/compose.yaml`](../../docker-compose/media/compose.yaml) | 2026-11-07 |
| `kr-ccp-socketproxy-0301` | old storage box (MOS templates) | [`config-files/mos/containers.md`](../../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-socketproxy-0401` | infra VM | [`infra/compose.yaml`](../../docker-compose/infra/compose.yaml) | 2026-11-08 |
| `kr-ccp-socketproxy-0501` | apps VM | [`apps/compose.yaml`](../../docker-compose/apps/compose.yaml) | 2026-11-08 |
| `kr-ccp-logtidedb-0101` | Pi monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](logtide/compose.yaml) | |
| `kr-ccp-logtideredis-0101` | Pi monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](logtide/compose.yaml) | |
| `kr-ccp-logtideapi-0101` | Pi monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](logtide/compose.yaml) | |
| `kr-ccp-logtideworker-0101` | Pi monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](logtide/compose.yaml) | |
| `kr-ccp-logtideui-0101` | Pi monitoring host (archived 2026-11-19, #207) | [`archive/docker-compose/logtide/compose.yaml`](logtide/compose.yaml) | |
| `kr-ccp-jellyfin-0101` | media LXC | [`media/compose.yaml`](../../docker-compose/media/compose.yaml) | 2026-11-07 |
| `kr-ccp-mediasort-0101` | apps VM | [`apps/compose.yaml`](../../docker-compose/apps/compose.yaml) | 2026-11-10 |
| `kr-ccp-ollama-0101` | apps VM | [`apps/compose.yaml`](../../docker-compose/apps/compose.yaml) | 2026-11-10 |
| `kr-ccp-komga-0101` | media LXC | [`media/compose.yaml`](../../docker-compose/media/compose.yaml) | 2026-11-07 |
| `kr-ccp-homey-0101` | media LXC | [`media/compose.yaml`](../../docker-compose/media/compose.yaml) | 2026-11-07 |

Not containers: the Beszel agent on the infra VM and the apps VM runs natively (systemd), so it has no container name.

LXC guests (`kr-cxp-…`): `kr-cxp-media-0101` (homenas).

Not registered yet: anything started by hand outside these files (check `docker ps` on each host).
