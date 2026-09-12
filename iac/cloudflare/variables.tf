variable "cloudflare_api_token" {
  description = "Cloudflare API token. Needs Zone:Zone:Edit + Zone:DNS:Edit on the three zones below, plus Zone:Zone:Create at the account level for the very first apply (narrow it afterward). Passed in via TF_VAR_cloudflare_api_token from the CLOUDFLARE_API_TOKEN GitHub secret."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns these zones. Passed in via TF_VAR_cloudflare_account_id from the CLOUDFLARE_ACCOUNT_ID GitHub secret."
  type        = string
}
