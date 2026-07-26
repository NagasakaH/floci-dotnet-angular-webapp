provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway = var.floci_endpoint
    iam        = var.floci_endpoint
    lambda     = var.floci_endpoint
    sts        = var.floci_endpoint
  }
}
