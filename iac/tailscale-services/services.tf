# Tailscale Services: each gets https://<name>.<tailnet>.ts.net on 443.
# Add a service = add a line here. The host still has to advertise it with
# `tailscale serve --service=svc:<name> ...`; approval is automatic via
# autoApprovers.services in iac/tailscale/policy.hujson.

locals {
  services = {
    gatus           = "Status page"
    beszel          = "Monitoring hub"
    dozzle          = "Container log viewer"
    healthchecks    = "Job heartbeats (UI + ping endpoint)"

    # storage host (tag:storage)
    archivebox     = "Web archive"
    archivewarrior = "ArchiveTeam Warrior"
    scrutiny       = "Disk SMART health"
    kopia          = "Backup server UI"
    rustfs         = "S3 storage console"
    s3             = "S3 API (RustFS)"

    # homenas Docker stacks, served by the host (tag:storage)
    paperless       = "Document archive"
    cannoncommander = "File manager"
    immich          = "Photos"
    atuin           = "Shell history sync"
    hedgedoc        = "Markdown editor"
    filestash       = "File manager (storage backends)"
    rackpeek        = "Homelab inventory"
    arcane          = "Docker management and git-sync deploys (homenas)"

    # host admin UIs (Cockpit), auto-approved for tag:cockpit
    "cockpit-sexy" = "Host admin UI (monitoring host)"

    # infra VM (tag:infra)
    dockhand = "Docker management (home)"

    # media LXC (tag:media)
    jellyfin = "Media server"
    komga    = "Comics and books server"
  }
}

resource "tailscale_service" "this" {
  for_each = local.services

  name    = "svc:${each.key}"
  comment = each.value
  ports   = ["tcp:443"]
}
