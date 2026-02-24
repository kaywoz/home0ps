terraform {
  backend "s3" {
    endpoint   = "https://hel1.your-objectstorage.com"
    bucket     = "krypinet-iac"
    key        = "B9VAIBFMAPZA49IYDN3B"
    region     = "us-east-1"

    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
