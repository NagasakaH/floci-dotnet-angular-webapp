locals {
  workspace_config = {
    dev = {
      name_prefix                      = "floci-poc-dev"
      stage_name                       = "dev"
      aws_region                       = "ap-northeast-1"
      frontend_origin                  = "https://replace-with-cloudfront-domain.invalid"
      integration_timeout_milliseconds = 29000
    }
  }

  # `terraform validate` runs after `init -backend=false` in the default
  # workspace. Use dev only for offline schema validation; the guard below
  # prevents planning or applying to AWS from any workspace other than dev.
  config = lookup(local.workspace_config, terraform.workspace, local.workspace_config.dev)
}

resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = terraform.workspace == "dev"
      error_message = "Select the dev workspace before planning or applying the AWS stack."
    }
  }
}

module "application" {
  source                           = "../../modules/application"
  name_prefix                      = local.config.name_prefix
  hello_zip                        = abspath("${path.module}/../../artifacts/hello.zip")
  authorizer_zip                   = abspath("${path.module}/../../artifacts/authorizer.zip")
  cors_allow_origin                = local.config.frontend_origin
  stage_name                       = local.config.stage_name
  integration_timeout_milliseconds = local.config.integration_timeout_milliseconds

  depends_on = [terraform_data.workspace_guard]
}
