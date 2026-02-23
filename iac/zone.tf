# Get zone information by name
data "hetzner_dns_zone" "m41w423mu572un" {
  name = "m41w423mu572un.xyz"
}

# Create new record
resource "hetzner_dns_record" "test_resource" {
  name    = "@"
  type    = "TXT"
  ttl     = 3600
  value   = "so_much_test"
  zone_id = 850492
}
