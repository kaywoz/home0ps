terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.29.2" # exact pin; upgrades go in their own PR (see MISTAKES.md)
    }
  }
}

# Tailnet defaults to the one that owns the OAuth client. The client is scoped
# to Services only -- the ACL policy is owned by deploy-tailscale-acl.yml.
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
}
