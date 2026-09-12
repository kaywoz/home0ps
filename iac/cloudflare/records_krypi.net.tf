##############################################################################
# krypi.net — ported record-for-record from the CURRENT
# home0ps/iac/dns_records_krypi.net.tf (hcloud_zone_rrset), not from the
# stale terraform-cloudflare/cloudflare.tf.
#
# ttl = 1 means "automatic" and is required by Cloudflare whenever
# proxied = true; everything left DNS-only keeps the source zone's TTL (60s).
##############################################################################

#############################################
# CNAME records
#############################################

resource "cloudflare_dns_record" "cname_39580102" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "39580102"
  type    = "CNAME"
  content = "sendgrid.net"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_blog" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "blog"
  type    = "CNAME"
  content = "kaywozplayz.krypi.net"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cname_domainconnect" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "_domainconnect"
  type    = "CNAME"
  content = "_domainconnect.gd.domaincontrol.com"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_em1932" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "em1932"
  type    = "CNAME"
  content = "u39580102.wl103.sendgrid.net"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_ghpages" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "ghpages"
  type    = "CNAME"
  content = "kaywoz.github.io"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cname_kaywoz" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "kaywoz"
  type    = "CNAME"
  content = "kaywoz.github.io"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cname_kaywozplayz" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "kaywozplayz"
  type    = "CNAME"
  content = "kaywoz.github.io"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cname_url1230" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "url1230"
  type    = "CNAME"
  content = "sendgrid.net"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_www" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "www"
  type    = "CNAME"
  content = "kaywoz.github.io"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cname_s1_domainkey" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "s1._domainkey"
  type    = "CNAME"
  content = "s1.domainkey.tutanota.de"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_s2_domainkey" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "s2._domainkey"
  type    = "CNAME"
  content = "s2.domainkey.tutanota.de"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_mta_sts_underscore" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "_mta-sts"
  type    = "CNAME"
  content = "mta-sts.tutanota.de"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_mta_sts" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "mta-sts"
  type    = "CNAME"
  content = "mta-sts.tutanota.de"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_netbird_sh_internal" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "*.sh-internal"
  type    = "CNAME"
  content = "eu1.netbird.services"
  ttl     = 60
  proxied = false # wildcard — Cloudflare won't proxy this below Enterprise, and NetBird needs the real target anyway
}

resource "cloudflare_dns_record" "cname_netbird_hl_internal" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "*.hl-internal"
  type    = "CNAME"
  content = "eu1.netbird.services"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "cname_netbird_pub" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "*.pub"
  type    = "CNAME"
  content = "eu1.netbird.services"
  ttl     = 60
  proxied = false
}

#############################################
# MX record
#############################################

resource "cloudflare_dns_record" "mx_root" {
  zone_id  = data.cloudflare_zone.krypi_net.id
  name     = "@"
  type     = "MX"
  content  = "mail.tutanota.de"
  priority = 0
  ttl      = 60
}

#############################################
# TXT records
#############################################

resource "cloudflare_dns_record" "txt_dmarc" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "_dmarc"
  type    = "TXT"
  content = "v=DMARC1; p=quarantine; adkim=s"
  ttl     = 60
}

resource "cloudflare_dns_record" "txt_spf" {
  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "@"
  type    = "TXT"
  content = "v=spf1 include:spf.tutanota.de -all"
  ttl     = 60
}
