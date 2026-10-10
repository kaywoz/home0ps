# iac/cloudflare

Cloudflare DNS records, applied by `.github/workflows/deploy-cloudflare-dns.yml`
(plan on PR, apply on merge to `main` behind a manual approver).

## Zones

Zones are added by hand in the Cloudflare dashboard (Free plan); `zones.tf`
only looks them up by name. OpenTofu manages the records.

| Zone | File | What it is | Proxied |
|------|------|------------|---------|
| `krypi.net` | `records_krypi.net.tf`, `int-records.tf` | Personal domain: mail, GitHub Pages, SendGrid, internal proxy wildcards | Only the GitHub Pages CNAMEs (`www`, `blog`, `ghpages`, `kaywoz`, `kaywozplayz`); everything else DNS-only |
| `m41w423mu572un.xyz` | `records_m41w423mu572un.xyz.tf` | Detection-engineering training domain | None -- all DNS-only |
| `obviousphish.com` | `records_obviousphish.com.tf` | Phishing-simulation training domain | None -- all DNS-only |

Records in the two training zones are copied verbatim and kept as opaque
strings; don't reformat or "clean up" their values.

## Internal proxy DNS (`*.<id>.int.krypi.net`)

Each reverse-proxy installation gets one public wildcard A record pointing at the
host's Tailscale IP (`proxied = false`). Only tailnet members can reach the target;
individual service names are never published.

| ID   | Host  | Purpose                       |
|------|-------|-------------------------------|
| 0101 | nasty | NPM - local docker containers |
| 0201 | sexy  | NPM - main docker host (not yet online; commented out in `proxies.yaml`) |

**Source of truth:** `proxies.yaml`, read by `int-records.tf` with `for_each`.

**ID scheme:** First 2 numbers are member numbers, last 2 numbers are group numbers for groups/clusters etc.

**Add an installation:** add an entry to `proxies.yaml`, open a PR, confirm the
plan shows exactly one create, merge.

**Services:** add proxy hosts in that installation's NPM (e.g.
`<service>.<id>.int.krypi.net`). No DNS change needed.

**Certs:** managed in NPM — wildcard cert via DNS challenge (Cloudflare), one
dedicated DNS-edit token per NPM instance.
