#############################################
# CNAME Records
#############################################

resource "hcloud_zone_rrset" "cname_39580102" {
  zone = hcloud_zone.krypi.name
  name = "39580102"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "sendgrid.net." },
  ]
}

resource "hcloud_zone_rrset" "cname_autodiscover" {
  zone = hcloud_zone.krypi.name
  name = "autodiscover"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "autodiscover.outlook.com." },
  ]
}

resource "hcloud_zone_rrset" "cname_blog" {
  zone = hcloud_zone.krypi.name
  name = "blog"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "kaywozplayz.krypi.net." },
  ]
}

resource "hcloud_zone_rrset" "cname_domainconnect" {
  zone = hcloud_zone.krypi.name
  name = "_domainconnect"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "_domainconnect.gd.domaincontrol.com." },
  ]
}

resource "hcloud_zone_rrset" "cname_em1932" {
  zone = hcloud_zone.krypi.name
  name = "em1932"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "u39580102.wl103.sendgrid.net." },
  ]
}

resource "hcloud_zone_rrset" "cname_ghpages" {
  zone = hcloud_zone.krypi.name
  name = "ghpages"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "kaywoz.github.io." },
  ]
}

resource "hcloud_zone_rrset" "cname_kaywoz" {
  zone = hcloud_zone.krypi.name
  name = "kaywoz"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "github.io." },
  ]
}

resource "hcloud_zone_rrset" "cname_kaywozplayz" {
  zone = hcloud_zone.krypi.name
  name = "kaywozplayz"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "kaywoz.github.io." },
  ]
}

resource "hcloud_zone_rrset" "cname_url1230" {
  zone = hcloud_zone.krypi.name
  name = "url1230"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "sendgrid.net." },
  ]
}

resource "hcloud_zone_rrset" "cname_www" {
  zone = hcloud_zone.krypi.name
  name = "www"
  type = "CNAME"
  ttl  = 60

  records = [
    { value = "kaywoz.github.io." },
  ]
}

#############################################
# MX Records
#############################################

resource "hcloud_zone_rrset" "mx_root" {
  zone = hcloud_zone.krypi.name
  name = "@"
  type = "MX"

  records = [
    { value = "0 606660219.pamx1.hotmail.com." },
  ]
}

#############################################
# TXT Records
#############################################

resource "hcloud_zone_rrset" "txt_dmarc" {
  zone = hcloud_zone.krypi.name
  name = "_dmarc"
  type = "TXT"

  records = [
    { value = provider::hcloud::txt_record("v=DMARC1; p=none;") },
  ]
}

resource "hcloud_zone_rrset" "txt_root" {
  zone = hcloud_zone.krypi.name
  name = "@"
  type = "TXT"

  records = [
    { value = provider::hcloud::txt_record("v=spf1 include:outlook.com -all") },
  ]
}

resource "hcloud_zone_rrset" "txt_outlook" {
  zone = hcloud_zone.krypi.name
  name = "_outlook"
  type = "TXT"

  records = [
    { value = provider::hcloud::txt_record("606660219") },
  ]
}
