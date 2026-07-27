provider "aws" {
  region                      = local.config.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway = local.config.floci_endpoint
    dynamodb   = local.config.floci_endpoint
    iam        = local.config.floci_endpoint
    lambda     = local.config.floci_endpoint
    s3         = local.config.floci_endpoint
    sqs        = local.config.floci_endpoint
    sts        = local.config.floci_endpoint
  }
}
