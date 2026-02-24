terraform {
  backend "s3" {
    endpoint   = "https://hel1.your-objectstorage.com"
    bucket     = "krypinet-iac"
    key        = "B9VAIBFMAPZA49IYDN3B"

    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
