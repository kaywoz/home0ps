terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.25.0" # exact pin; upgrades go in their own PR (see MISTAKES.md)
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
