terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      version = "1.60.1"
    }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

provider "hcloud" {
  token = var.hcloud_token
}
