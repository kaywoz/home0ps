# NetBird (archived 2026-10-03)

NetBird is no longer managed from this repo.

- `netbird.tf` managed a single resource, `netbird_group.test`. It was
  **forgotten, not destroyed**: the group may still exist in NetBird, but
  OpenTofu no longer tracks it (the Hetzner config moved to a fresh state in
  `iac/hetzner/`, and the old state object was retired).
- The NetBird provider, the `netbird_token` variable and the `NETBIRD_TOKEN`
  secret were removed. The token itself has been revoked.
- The NetBird wildcard CNAMEs (`*.sh-internal`, `*.hl-internal`, `*.pub`) were
  removed from `iac/cloudflare/records_krypi.net.tf` in a separate PR.

Kept for reference only. Nothing in this folder is applied by any workflow.
