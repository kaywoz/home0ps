##############################################################################
# T-Pot honeypot, LLM edition (kaywoz/home0ps#291).
#
# Untrusted by design: it has its own SSH key and no Tailscale, and it has no
# path into home0ps. T-Pot itself is installed on the host, not here (see
# config-files/tpot/README.md). Its installer moves OpenSSH to tcp/64295;
# tcp/22 then belongs to the SSH honeypot.
##############################################################################

# Used only for this host. Never reuse the key elsewhere.
resource "hcloud_ssh_key" "tpot" {
  name       = "he-all-tpot-0101"
  public_key = var.tpot_ssh_public_key
}

resource "hcloud_firewall" "tpot" {
  name = "he-all-tpot-0101"

  # Honeypot ports: everything up to 64000, from anywhere (T-Pot README).
  rule {
    description = "honeypots tcp"
    direction   = "in"
    protocol    = "tcp"
    port        = "1-64000"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "honeypots udp"
    direction   = "in"
    protocol    = "udp"
    port        = "1-64000"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "icmp"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  # Admin: OpenSSH (64295) and the web UI (64297), home IP only.
  rule {
    description = "admin ssh"
    direction   = "in"
    protocol    = "tcp"
    port        = "64295"
    source_ips  = ["${var.admin_ipv4}/32"]
  }

  rule {
    description = "admin web ui"
    direction   = "in"
    protocol    = "tcp"
    port        = "64297"
    source_ips  = ["${var.admin_ipv4}/32"]
  }
}

resource "hcloud_server" "honeypot" {
  name         = "he-all-tpot-0101"
  image        = "debian-13"
  server_type  = "cpx22" # below T-Pot's 8 GB guidance; resize when load shows it's needed
  location     = "hel1"
  ssh_keys     = [hcloud_ssh_key.tpot.id]
  firewall_ids = [hcloud_firewall.tpot.id]

  labels = {
    role = "honeypot"
    zone = "untrusted"
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}

output "tpot_ipv4" {
  description = "Public IPv4 of the T-Pot server."
  value       = hcloud_server.honeypot.ipv4_address
}
