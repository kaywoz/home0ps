#############################################
# Zone definition
#############################################

resource "hcloud_zone" "obviousphish" {
  name = "obviousphish.com"
  mode = "primary"
}
