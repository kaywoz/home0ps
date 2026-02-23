terraform {
  required_providers {
    hetzner = {
      source = "opsheaven/hetzner"
      version = "0.2.0"
    }
  }
}
provider "hetzner" {
  dns_api_enabled = true
  dns_api_token = "3y8pajkX4nXIHfeg0yC4VJp696pDfp98"
#  dns_api_token   = "BULjGaqiiHqivVUqSd3Bbcii1lXDHyumKhUrFWloZxvkE8uMf4Z3ubNibLl8dQLl"
}
