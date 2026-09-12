##############################################################################
# State backend for the Cloudflare DNS config (iac/cloudflare/).
#
# Reuses the same Hetzner Object Storage endpoint/bucket that home0ps/iac/
# already uses (see ../backend.tf), but a distinct key so this state is
# isolated from the Hetzner compute + NetBird state — a DNS-only apply here
# never touches, and is never touched by, that state file.
#
# Credentials: same HETZNER_ACCESS_KEY_ID / HETZNER_SECRET_ACCESS_KEY repo
# secrets already used by deploy-iac.yml, mapped to AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY env vars (the S3 backend's expected names) in
# deploy-cloudflare-dns.yml.
##############################################################################

terraform {
  backend "s3" {
    endpoint = "https://hel1.your-objectstorage.com"
    bucket   = "krypinet-iac"
    key      = "cloudflare-dns/terraform.tfstate"
    region   = "us-east-1"

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
