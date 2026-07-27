locals {
  workspace_config = {
    dev = {
      name_prefix                      = "floci-poc-dev"
      stage_name                       = "dev"
      aws_region                       = "ap-northeast-1"
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

data "aws_ssm_parameter" "frontend_origin" {
  name = "/floci-poc/${terraform.workspace}/frontend-origin"
}

data "aws_ssm_parameter" "cognito_issuer" {
  name = "/floci-poc/${terraform.workspace}/cognito-issuer"
}

data "aws_ssm_parameter" "cognito_client_id" {
  name = "/floci-poc/${terraform.workspace}/cognito-client-id"
}

module "application" {
  source                           = "../../modules/application"
  name_prefix                      = local.config.name_prefix
  hello_zip                        = abspath("${path.module}/../../artifacts/hello.zip")
  authorizer_zip                   = abspath("${path.module}/../../artifacts/authorizer.zip")
  search_jobs_zip                  = abspath("${path.module}/../../artifacts/search-jobs.zip")
  cors_allow_origin                = data.aws_ssm_parameter.frontend_origin.value
  cognito_issuer                   = data.aws_ssm_parameter.cognito_issuer.value
  cognito_client_id                = data.aws_ssm_parameter.cognito_client_id.value
  stage_name                       = local.config.stage_name
  integration_timeout_milliseconds = local.config.integration_timeout_milliseconds
  enable_gateway_responses         = true

  depends_on = [terraform_data.workspace_guard]
}

output "search_results_bucket" {
  value = module.application.search_results_bucket
}

output "search_jobs_table" {
  value = module.application.search_jobs_table
}
