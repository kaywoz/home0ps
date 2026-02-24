#############################################
# Zone definition
#############################################

resource "hcloud_zone" "krypi" {
  name = "krypi.net"
  mode = "primary"
}
