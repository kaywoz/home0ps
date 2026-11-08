# Container register

Every container on the home0ps hosts, so names stay unique. Convention (CLAUDE.md §8): `<location>-<class>-<service>-<GGMM>`, e.g. `kr-ccp-gatus-0101`; the suffix is **individual + group** (kaywoz, 2026-11-08): `0101` = 1st individual in group 1. An independent further instance of the same service is the next **group** (`0102`, `0103`, … in creation order); members of an HA pair share a group (`0104` + `0204` = 1st and 2nd individual in group 4).

**Adding a container:** take the next free group for its service here (or the next individual in the group, for an HA member), use it in the compose/deploy settings, and add the row in the same change. Hosts by role only (real device names never in git).

| Container | Host role | Defined in | Since |
|---|---|---|---|
| `kr-ccp-gatus-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszel-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszelagent-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-beszelagent-0102` | storage host (MOS) | [`config-files/mos/containers.md`](../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-dozzle-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-socketproxy-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-socketproxy-0102` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-socketproxy-0103` | storage host (MOS) | [`config-files/mos/containers.md`](../config-files/mos/containers.md) | 2026-11-08 |
| `kr-ccp-logtidedb-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-logtideredis-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-logtideapi-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-logtideworker-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-logtideui-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-healthchecks-0101` | monitoring host | [`monitoring/compose.yaml`](monitoring/compose.yaml) | |
| `kr-ccp-jellyfin-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-komga-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |
| `kr-ccp-homey-0101` | media LXC | [`media/compose.yaml`](media/compose.yaml) | 2026-11-07 |

LXC guests (`kr-cxp-…`): `kr-cxp-media-0101` (storage host).

Not registered yet: anything started by hand outside these files (check `docker ps` on each host).
