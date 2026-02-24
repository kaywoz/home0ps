#############################################
# A Records
#############################################

resource "hcloud_zone_rrset" "a_root" {
  zone = hcloud_zone.obviousphish.name
  name = "@"
  type = "A"
  ttl  = 3600

  records = [
    { value = "34.38.169.145" },
  ]
}

resource "hcloud_zone_rrset" "a_example" {
  zone = hcloud_zone.obviousphish.name
  name = "example"
  type = "A"
  ttl  = 3600

  records = [
    { value = "34.38.169.145" },
  ]
}

resource "hcloud_zone_rrset" "a_example_really" {
  zone = hcloud_zone.obviousphish.name
  name = "example.really"
  type = "A"
  ttl  = 3600

  records = [
    { value = "35.228.144.182" },
  ]
}

resource "hcloud_zone_rrset" "a_login" {
  zone = hcloud_zone.obviousphish.name
  name = "login"
  type = "A"
  ttl  = 3600

  records = [
    { value = "34.38.169.145" },
  ]
}

resource "hcloud_zone_rrset" "a_microsoft365" {
  zone = hcloud_zone.obviousphish.name
  name = "microsoft365"
  type = "A"
  ttl  = 3600

  records = [
    { value = "34.38.169.145" },
  ]
}

resource "hcloud_zone_rrset" "a_office365" {
  zone = hcloud_zone.obviousphish.name
  name = "office365"
  type = "A"
  ttl  = 3600

  records = [
    { value = "34.38.169.145" },
  ]
}

#############################################
# TXT Records
#############################################

resource "hcloud_zone_rrset" "txt_hippopotomonstrosesquippedaliophobia" {
  zone = hcloud_zone.obviousphish.name
  name = "hippopotomonstrosesquippedaliophobia"
  type = "TXT"
  ttl  = 3600

  records = [
    { value = provider::hcloud::txt_record("The gentlemanimals shared their fear.") },
  ]
}

resource "hcloud_zone_rrset" "txt_llanfairpwllgwyngyllgogerychwyrndrobwyllllantysiliogogogoch" {
  zone = hcloud_zone.obviousphish.name
  name = "llanfairpwllgwyngyllgogerychwyrndrobwyllllantysiliogogogoch"
  type = "TXT"
  ttl  = 3600

  records = [
    { value = provider::hcloud::txt_record("aGlwcG9wb3RvbW9uc3Ryb3Nlc3F1aXBwZWRhbGlvcGhvYmlhCg==") },
  ]
}
