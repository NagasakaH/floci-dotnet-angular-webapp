locals {
  workspace_config = {
    dev = {
      aws_region      = "ap-northeast-1"
      floci_endpoint  = "http://localhost:4566"
      frontend_origin = "http://localhost:4200"
    }
  }

  config = local.workspace_config[terraform.workspace]
}

module "application" {
  source                           = "../../modules/application"
  name_prefix                      = "floci-poc-${terraform.workspace}"
  hello_zip                        = abspath("${path.module}/../../artifacts/hello.zip")
  authorizer_zip                   = abspath("${path.module}/../../artifacts/authorizer.zip")
  cors_allow_origin                = local.config.frontend_origin
  stage_name                       = terraform.workspace
  integration_timeout_milliseconds = 50
}
