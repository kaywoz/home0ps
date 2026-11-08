# Naming standard

One scheme for everything logical in home0ps — VMs, LXCs, containers, appliances, cloud servers — and private names for physical hardware. Decided by kaywoz, 2026-11-08. Containers are registered in [`docker-compose/CONTAINERS.md`](docker-compose/CONTAINERS.md).

## Two layers

| Layer | Name | In git |
|---|---|---|
| **Physical hardware** — anything you can touch: servers, NAS, Pi, switches, APs, KVMs, UPS | a word ending in **`-y`** | **never** (CLAUDE.md §4; DNS records and `svc:<app>-<device>` are the only exceptions) |
| **Logical** — VMs, LXCs, containers, appliances, cloud servers, templates | the scheme below | yes |

## Scheme

```text
<site>-<type><platform><env>-<service>-<GGMM>
```

Fields are separated by `-` only; inside a field only lowercase letters and digits (`beszelagent`, not `beszel-agent`), so every name splits into exactly four parts. The whole name stays DNS-safe (≤ 63 characters): usable as hostname, MagicDNS name and container name.

| Field | Code | Meaning |
|---|---|---|
| **site** | `kr` | home (Krypinet), lab included |
| | `he` | Hetzner |
| **type** | `c` | custom (own build/config) |
| | `a` | appliance (vendor-built: Xen Orchestra, firewall images, …) |
| | `t` | template (golden images for VMs/containers) |
| **platform** | `c` | container (OCI/Docker) |
| | `x` | LXC |
| | `l` | Linux (VM or cloud server) |
| | `w` | Windows |
| | `e` | embedded/firmware |
| **env** | `p` | production |
| | `d` | development (development and testing) |
| | `l` | lab (untrusted zone) |
| **service** | | what it is or does: `beszelagent`, `xenorchestra`, `apps`, `infra` |
| **GGMM** | | **group, then member** (below) |

New site or code: add it here first, in the same change that uses it.

### GGMM — group first, member second

- `0101` — group 1, member 1.
- An **independent further instance** of the same service is the next group: `0201`, `0301`, … in creation order.
- Members of an **HA pair or cluster** share a group: `0401` + `0402`. They sort next to each other everywhere.
- Groups are counted per `<service>` across all sites and classes.

## Examples

| Name | Meaning |
|---|---|
| `kr-ccp-beszelagent-0101` | home, custom container, production, Beszel agent, group 1 |
| `kr-ccp-socketproxy-0301` | the 3rd independent socket proxy |
| `kr-cxp-media-0101` | home, custom LXC, production, media |
| `kr-clp-apps-0101` | home, custom Linux VM, production, apps |
| `he-alp-xenorchestra-0101` | Hetzner, appliance Linux, production, Xen Orchestra |
| `kr-all-xenorchestra-0201` | home, appliance Linux, lab — a separate instance, so group 2 |
| `kr-cll-testdocker-0101` + `-0102` | a lab pair: group 1, members 1 and 2 |
| `kr-tlp-debian13-0101` | home, template Linux, production, Debian 13 image |
