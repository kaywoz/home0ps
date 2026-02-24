terraform {
  backend "s3" {
    endpoint   = "${env.S3_ENDPOINT}"
    bucket     = "${env.S3_BUCKET}"
    key        = "${env.S3_KEY}"

    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
