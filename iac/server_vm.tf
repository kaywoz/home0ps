# Create a new server running debian
resource "hcloud_server" "pangolin" {
  name        = "hh-clp-pangolin-0101"
  image       = "debian-12"
  server_type = "cax11"
  location    = "hel1"
  ssh_keys    = ["github"]
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
