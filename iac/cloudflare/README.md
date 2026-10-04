# iac/cloudflare

Cloudflare DNS records, applied by `.github/workflows/deploy-cloudflare-dns.yml`
(plan on PR, apply on merge to `main` behind a manual approver).

## Internal proxy DNS (`*.<id>.int.krypi.net`)

Each reverse-proxy installation gets one public wildcard A record pointing at the
host's Tailscale IP (`proxied = false`). Only tailnet members can reach the target;
individual service names are never published.

| ID   | Purpose                       |
|------|-------|-------------------------------|
| 0101 | NPM - local docker containers |
| 0201 | NPM - main docker host (not yet online; commented out in `proxies.yaml`) |

**Source of truth:** `proxies.yaml`, read by `int-records.tf` with `for_each`.

**ID scheme:** First 2 numbers are member numbers, last 2 numbers are group numbers for groups/clusters etc.

**Add an installation:** add an entry to `proxies.yaml`, open a PR, confirm the
plan shows exactly one create, merge.

**Services:** add proxy hosts in that installation's NPM (e.g.
`<service>.<id>.int.krypi.net`). No DNS change needed.

**Certs:** managed in NPM — wildcard cert via DNS challenge (Cloudflare), one
dedicated DNS-edit token per NPM instance.
