variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "tpot_ssh_public_key" {
  description = "OpenSSH public key used only for the T-Pot server (secret TPOT_SSH_PUBLIC_KEY)."
  type        = string
}

variable "admin_ipv4" {
  description = "Home public IPv4 allowed to reach T-Pot's admin ports (secret HOME_PUBLIC_IPV4)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(cidrhost("${var.admin_ipv4}/32", 0))
    error_message = "admin_ipv4 must be a single IPv4 address, without a prefix."
  }
}
