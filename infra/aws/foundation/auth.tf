data "aws_ssm_parameters_by_path" "deployed" {
  path = "/floci-poc/${terraform.workspace}/"
}

locals {
  deployed_parameters = zipmap(
    data.aws_ssm_parameters_by_path.deployed.names,
    nonsensitive(data.aws_ssm_parameters_by_path.deployed.values)
  )
  # A new account has no CloudFront URL before its first apply. The first pass
  # creates the distribution with this inert callback, and the second pass
  # reads the SSM URL and publishes the usable Edge/Cognito configuration.
  frontend_url = trimsuffix(
    lookup(
      local.deployed_parameters,
      "/floci-poc/${terraform.workspace}/frontend-origin",
      "https://bootstrap.invalid"
    ),
    "/"
  )
  callback_url = "${local.frontend_url}/auth/callback"
}

resource "aws_cognito_user_pool" "frontend" {
  name                     = "${local.config.name_prefix}-frontend"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  tags = {
    Application = "floci-poc"
    Environment = terraform.workspace
  }

  depends_on = [terraform_data.workspace_guard]
}

resource "aws_cognito_user_pool_domain" "frontend" {
  domain                = "${local.config.name_prefix}-${data.aws_caller_identity.current.account_id}"
  user_pool_id          = aws_cognito_user_pool.frontend.id
  managed_login_version = 1
}

resource "aws_cognito_user_pool_client" "frontend" {
  name         = "${local.config.name_prefix}-cloudfront"
  user_pool_id = aws_cognito_user_pool.frontend.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = [local.callback_url]
  logout_urls                          = [local.frontend_url]
  default_redirect_uri                 = local.callback_url
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  explicit_auth_flows                  = ["ALLOW_ADMIN_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  access_token_validity                = 1
  id_token_validity                    = 1
  refresh_token_validity               = 1

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_group" "hello_readers" {
  name         = "hello-readers"
  user_pool_id = aws_cognito_user_pool.frontend.id
  description  = "Users allowed to call GET /api/hello"
  precedence   = 10
}

resource "aws_ssm_parameter" "cognito_issuer" {
  name        = "/floci-poc/${terraform.workspace}/cognito-issuer"
  description = "Trusted Cognito issuer for the API Authorizer"
  type        = "String"
  value       = "https://cognito-idp.${local.config.aws_region}.amazonaws.com/${aws_cognito_user_pool.frontend.id}"
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name        = "/floci-poc/${terraform.workspace}/cognito-client-id"
  description = "Trusted Cognito app client ID for the API Authorizer"
  type        = "String"
  value       = aws_cognito_user_pool_client.frontend.id
}

data "archive_file" "frontend_auth_gate" {
  type        = "zip"
  output_path = "${path.module}/.terraform/frontend-auth-gate.zip"

  source {
    content  = file("${path.module}/../../../src/FrontendAuthGate/index.mjs")
    filename = "index.mjs"
  }

  source {
    content = jsonencode({
      cognitoDomain = "${aws_cognito_user_pool_domain.frontend.domain}.auth.${local.config.aws_region}.amazoncognito.com"
      clientId      = aws_cognito_user_pool_client.frontend.id
      callbackUrl   = local.callback_url
      frontendUrl   = local.frontend_url
      issuer        = "https://cognito-idp.${local.config.aws_region}.amazonaws.com/${aws_cognito_user_pool.frontend.id}"
    })
    filename = "config.json"
  }
}

data "aws_iam_policy_document" "edge_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "frontend_auth_gate" {
  name               = "${local.config.name_prefix}-frontend-auth-gate"
  assume_role_policy = data.aws_iam_policy_document.edge_assume.json
}

resource "aws_iam_role_policy" "frontend_auth_gate_logs" {
  name = "${local.config.name_prefix}-frontend-auth-gate-logs"
  role = aws_iam_role.frontend_auth_gate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
    }]
  })
}

resource "aws_lambda_function" "frontend_auth_gate" {
  provider = aws.us_east_1

  function_name    = "${local.config.name_prefix}-frontend-auth-gate"
  role             = aws_iam_role.frontend_auth_gate.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.frontend_auth_gate.output_path
  source_code_hash = data.archive_file.frontend_auth_gate.output_base64sha256
  memory_size      = 128
  timeout          = 5
  publish          = true
}
