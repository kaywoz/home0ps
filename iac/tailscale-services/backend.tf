##############################################################################
# State backend for Tailscale Services (iac/tailscale-services/).
#
# Partial configuration: endpoint and bucket are NOT in this file. They are
# supplied at init time from the S3_ENDPOINT / S3_BUCKET repo secrets:
#
#   tofu init -backend-config="endpoint=$S3_ENDPOINT" \
#             -backend-config="bucket=$S3_BUCKET"
#
# `key` is the state file's path inside the bucket (like a filename), not a
# credential. Credentials come from HETZNER_ACCESS_KEY_ID /
# HETZNER_SECRET_ACCESS_KEY, mapped to AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY in deploy-tailscale-services.yml.
##############################################################################

terraform {
  backend "s3" {
    key    = "tailscale-services/terraform.tfstate"
    region = "us-east-1"

    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
