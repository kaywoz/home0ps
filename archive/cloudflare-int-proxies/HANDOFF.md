# Handoff: internal proxy wildcard DNS in home0ps

Read CLAUDE.md and mistakes.md in this repo before starting.

## Task
Add one public wildcard A record per reverse-proxy installation to the krypi.net
zone, managed in `iac/cloudflare/`, through the normal PR -> plan -> merge -> apply flow.

## Scope
DNS records only. Do not touch Tailscale ACLs, NPM, certificates, or hosts.
Reverse proxies are Nginx Proxy Manager instances managed manually by me.

## Decisions already made
- Naming: `*.<id>.int.krypi.net`, where `<id>` is a four-digit proxy installation ID
  (not a hostname), so a proxy can move hosts by repointing one record.
- Current installations:
  - `0101` -> NPM on nasty (its local Docker containers)
  - `0201` -> NPM on sexy (main Docker host)
  - Future: `0301`, etc.
- Records point at each host's Tailscale IP (100.64.0.0/10), `proxied = false`.
- Source of truth is `iac/cloudflare/proxies.yaml`; Terraform reads it with `for_each`.
- Per-service names (e.g. `jellyfin.0201.int.krypi.net`) are handled in NPM only;
  no per-service DNS records.

## Draft files (provided alongside this brief)
- `iac/cloudflare/proxies.yaml`: placeholder IPs, need real values
- `iac/cloudflare/int-records.tf`: written for Cloudflare provider v5
- `iac/cloudflare/README-int-records.md`: merge into existing README

## Before committing
1. Replace placeholder IPs with real Tailscale IPs for nasty and sexy (ask me).
2. Change `var.zone_id` to whatever the existing `iac/cloudflare` code uses.
3. If the provider is pinned to v4, use `cloudflare_record` instead of `cloudflare_dns_record`.
4. Run fmt/validate/plan. The plan must show exactly 2 creates and nothing else.

## Done when
`dig +short x.0101.int.krypi.net` and `dig +short x.0201.int.krypi.net` return
the correct Tailscale IPs.
