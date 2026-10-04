# Wildcard DNS records for internal reverse-proxy installations.
# Source of truth: proxies.yaml

locals {
  proxies = yamldecode(file("${path.module}/proxies.yaml")).proxies
}

resource "cloudflare_dns_record" "proxy_wildcard" {
  for_each = local.proxies

  zone_id = data.cloudflare_zone.krypi_net.id
  name    = "*.${each.key}.int.krypi.net"
  type    = "A"
  content = each.value.tailscale_ip
  ttl     = 300
  proxied = false # must stay false: Cloudflare cannot reach Tailscale (100.x) addresses
  comment = "proxy ${each.key} on ${each.value.host} - managed by home0ps"

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9]{4}$", each.key))
      error_message = "Proxy IDs must be four digits (e.g. 0101)."
    }
    precondition {
      condition     = can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.", each.value.tailscale_ip))
      error_message = "tailscale_ip must be a valid address in 100.64.0.0/10."
    }
  }
}

output "proxy_wildcards" {
  description = "Wildcard record per proxy installation"
  value       = { for id, r in cloudflare_dns_record.proxy_wildcard : id => "${r.name} -> ${r.content}" }
}
