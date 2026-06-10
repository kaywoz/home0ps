resource "netbird_dns_zone" "internal" {
  name                 = "sh-internal"
  domain               = "sh-internal.krypi.net"
  enabled              = true
  enable_search_domain = true
  distribution_groups  = [netbird_group.example.id]
}

resource "netbird_group" "example" {
  name = "ingress"
  peers = [
    shpc-netbird-0101.netbird.cloud,
  ]
}
