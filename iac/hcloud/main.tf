terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      version = "1.60.1"
    }
  }
}

provider "hcloud" {
  token = "BULjGaqiiHqivVUqSd3Bbcii1lXDHyumKhUrFWloZxvkE8uMf4Z3ubNibLl8dQLl"
}
