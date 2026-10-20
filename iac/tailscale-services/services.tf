# Tailscale Services: each gets https://<name>.<tailnet>.ts.net on 443.
# Add a service = add a line here. The host still has to advertise it with
# `tailscale serve --service=svc:<name> ...`; approval is automatic via
# autoApprovers.services in iac/tailscale/policy.hujson.

locals {
  services = {
    gatus         = "Status page"
    cockpit       = "Host admin UI"
    beszel        = "Monitoring hub"
    dozzle        = "Container log viewer"
    logtide       = "Log management UI"
    "logtide-api" = "Log management API (UI calls + log ingest)"
    healthchecks  = "Job heartbeats (UI + ping endpoint)"

    # storage host (tag:storage)
    archivebox     = "Web archive"
    archivewarrior = "ArchiveTeam Warrior"
    scrutiny       = "Disk SMART health"
    kopia          = "Backup server UI"
    rustfs         = "S3 storage console"

    # apps host (tag:observed)
    "cockpit-apps" = "Host admin UI (apps host)"
  }
}

resource "tailscale_service" "this" {
  for_each = local.services

  name    = "svc:${each.key}"
  comment = each.value
  ports   = ["tcp:443"]
}
