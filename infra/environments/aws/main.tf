module "api" {
  source            = "../../modules/api"
  name_prefix       = "floci-poc"
  hello_zip         = abspath("${path.module}/../../artifacts/hello.zip")
  authorizer_zip    = abspath("${path.module}/../../artifacts/authorizer.zip")
  cors_allow_origin = var.frontend_origin
  stage_name        = "prod"
}
