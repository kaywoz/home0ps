##############################################################################
# State backend for the Cloudflare DNS config (iac/cloudflare/).
#
# Partial configuration: endpoint and bucket are NOT in this file. They are
# supplied at init time from the S3_ENDPOINT / S3_BUCKET repo secrets (same
# bucket as iac/hetzner/, distinct key so the two states stay isolated):
#
#   tofu init -backend-config="endpoint=$S3_ENDPOINT" \
#             -backend-config="bucket=$S3_BUCKET"
#
# Credentials: HETZNER_ACCESS_KEY_ID / HETZNER_SECRET_ACCESS_KEY repo
# secrets, mapped to AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in
# deploy-cloudflare-dns.yml.
##############################################################################

terraform {
  backend "s3" {
    key    = "cloudflare-dns/terraform.tfstate"
    region = "us-east-1"

    skip_credentials_validation = true
    skip_region_validation      = true

    # Terraform/OpenTofu >=1.10 native S3 locking via conditional PutObject
    # (If-None-Match). NOT YET VERIFIED against Hetzner Object Storage —
    # this is checklist item 4.6. If `tofu init`/`apply` errors out on
    # locking, delete this line and rely on the GitHub Actions concurrency
    # group in deploy-cloudflare-dns.yml as the only serialization instead.
    use_lockfile = true
  }
}
