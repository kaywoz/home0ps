resource "netbird_group" "ingress" {
  name = "ingress"
} ## add all regular groups here

resource "netbird_peer" "ingress-netbird" {
  id                            = "d057h0jl0ubs73cftnp0"
  ssh_enabled                   = false
  name                          = "shpc-netbird-0101"
  inactivity_expiration_enabled = false
  approval_required             = false
  login_expiration_enabled      = false
}
