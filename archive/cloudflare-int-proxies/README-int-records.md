## Internal proxy DNS (`*.<id>.int.krypi.net`)

Each reverse-proxy installation gets one public wildcard A record pointing at the
host's Tailscale IP. Only tailnet members can reach the target; individual
service names are never published.

| ID   | Host  | Purpose                     |
|------|-------|-----------------------------|
| 0101 | nasty | NPM - local docker containers |
| 0201 | sexy  | NPM - main docker host        |

**ID scheme:** <fill in>

**Add an installation:** add an entry to `proxies.yaml`, open a PR, confirm the
plan shows exactly one create, merge.

**Services:** add proxy hosts in that installation's NPM (e.g.
`jellyfin.0201.int.krypi.net`). No DNS change needed.

**Certs:** managed in NPM — wildcard cert via DNS challenge (Cloudflare), one
dedicated DNS-edit token per NPM instance.
