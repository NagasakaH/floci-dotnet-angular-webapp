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
  search_jobs_zip                  = abspath("${path.module}/../../artifacts/search-jobs.zip")
  file_ingest_zip                  = abspath("${path.module}/../../artifacts/file-ingest.zip")
  authentication_mode              = "local"
  cors_allow_origin                = local.config.frontend_origin
  stage_name                       = terraform.workspace
  integration_timeout_milliseconds = 50
  enable_gateway_responses         = false
  aws_service_endpoint             = "http://floci:4566"
  public_s3_endpoint               = "http://localhost:4566"
}

output "search_results_bucket" {
  value = module.application.search_results_bucket
}

output "search_jobs_table" {
  value = module.application.search_jobs_table
}

output "file_ingest_bucket" {
  value = module.application.file_ingest_bucket
}

output "file_jobs_table" {
  value = module.application.file_jobs_table
}
