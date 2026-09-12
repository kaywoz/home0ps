##############################################################################
# Zone lookups (not creation) for the three domains being migrated off
# Hetzner DNS. The zones are added by hand in the Cloudflare dashboard
# ("Add a domain", Free plan) -- this just looks each one up by name so the
# records files below can reference its zone_id.
#
# Why a data source instead of `resource "cloudflare_zone"`: creating a zone
# via the API needs an account-level "create zone" permission that's
# separate from (and easy to get wrong/miss) the "Zone DNS Edit" permission
# used for everything else here. Since zones are added rarely and records
# change constantly, it's simpler to keep zone lifecycle manual and let
# Terraform manage records only -- the token never needs the extra
# permission at all.
##############################################################################

data "cloudflare_zone" "krypi_net" {
  filter = { name = "krypi.net" }
}

data "cloudflare_zone" "m41w423mu572un_xyz" {
  filter = { name = "m41w423mu572un.xyz" }
}

data "cloudflare_zone" "obviousphish_com" {
  filter = { name = "obviousphish.com" }
}
