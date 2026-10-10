variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID (Services scope only)"
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret (Services scope only)"
  type        = string
  sensitive   = true
}
