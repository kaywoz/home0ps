##############################################################################
# One cloudflare_zone per domain being migrated off Hetzner DNS.
#
# Applying this creates each zone in a "pending nameservers" state in
# Cloudflare — inactive and non-disruptive until you actually change NS at
# Hetzner (checklist phase 7). Cloudflare assigns two nameservers per zone
# on creation; note them down for the pre-cutover verification step.
##############################################################################

resource "cloudflare_zone" "krypi_net" {
  account = { id = var.cloudflare_account_id }
  name    = "krypi.net"
}

resource "cloudflare_zone" "m41w423mu572un_xyz" {
  account = { id = var.cloudflare_account_id }
  name    = "m41w423mu572un.xyz"
}

resource "cloudflare_zone" "obviousphish_com" {
  account = { id = var.cloudflare_account_id }
  name    = "obviousphish.com"
}
