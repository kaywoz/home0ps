##############################################################################
# obviousphish.com — security-training / phishing-simulation domain.
#
# Ported record-for-record from the CURRENT
# home0ps/iac/dns_recordsobviousphish.com.tf. All records DNS-only: these
# point at specific external test IPs for the training exercises.
##############################################################################

#############################################
# A records
#############################################

resource "cloudflare_dns_record" "a_root" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "@"
  type    = "A"
  content = "34.38.169.145"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "a_example" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "example"
  type    = "A"
  content = "34.38.169.145"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "a_example_really" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "example.really"
  type    = "A"
  content = "35.228.144.182"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "a_login" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "login"
  type    = "A"
  content = "34.38.169.145"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "a_microsoft365" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "microsoft365"
  type    = "A"
  content = "34.38.169.145"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "a_office365" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "office365"
  type    = "A"
  content = "34.38.169.145"
  ttl     = 3600
  proxied = false
}

#############################################
# TXT records
#############################################

resource "cloudflare_dns_record" "txt_hippopotomonstrosesquippedaliophobia" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "hippopotomonstrosesquippedaliophobia"
  type    = "TXT"
  ttl     = 3600
  content = "The gentlemanimals shared their fear."
}

resource "cloudflare_dns_record" "txt_llanfairpwllgwyngyllgogerychwyrndrobwyllllantysiliogogogoch" {
  zone_id = cloudflare_zone.obviousphish_com.id
  name    = "llanfairpwllgwyngyllgogerychwyrndrobwyllllantysiliogogogoch"
  type    = "TXT"
  ttl     = 3600
  content = "aGlwcG9wb3RvbW9uc3Ryb3Nlc3F1aXBwZWRhbGlvcGhvYmlhCg=="
}
