resource "netbird_dns_zone" "internal" {
  name                 = "sh-internal"
  domain               = "sh-internal.krypi.net"
  enabled              = true
  enable_search_domain = true
  distribution_groups  = [netbird_group.example.id]
}

resource "netbird_network_resource" "example" {
  network_id  = netbird_network.example.id
  name        = "shpc-netbird-0101.netbird.cloud"
  description = "shpc-netbird-0101.netbird.cloud"
  address     = "172.16.31.10/32"
  groups      = [ingress]
  enabled     = true
}