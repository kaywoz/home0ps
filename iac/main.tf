# 1. PROVIDER CONFIGURATION BLOCK (REQUIRED)
terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      version = "~> 1.60" # Use version constraint for stability
    }
    netbird = {
      # This line tells Terraform where to find the NetBird API provider.
      source = "registry.terraform.io/netbirdio/netbird"
      version = "0.0.9" # Or specify a concrete version if needed
    }
  }
}

# 2. VARIABLE DEFINITIONS (The Input Tokens)
variable "hcloud_token" {
  description = "Hetzner Cloud API Token."
  type        = string
  sensitive   = true
}

variable "netbird_token" {
  description = "NetBird Management Access Token."
  type        = string
  sensitive   = true
}


# 3. PROVIDER INITIALIZATION (How the tokens are passed)
provider "hcloud" {
  token = var.hcloud_token
}

/* 
   If you intend to use NetBird in your infrastructure code, you must initialize its provider like this:   # This block initializes the connection to the NetBird API using your token.*/
provider "netbird" {
  token = var.netbird_token
}