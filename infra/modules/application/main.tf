data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "logs" {
  name = "${var.name_prefix}-lambda-logs"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "hello" {
  function_name    = "${var.name_prefix}-hello"
  role             = aws_iam_role.lambda.arn
  runtime          = var.hello_lambda_runtime
  handler          = "HelloApi::HelloApi.Function::Handler"
  filename         = var.hello_zip
  source_code_hash = filebase64sha256(var.hello_zip)
  timeout          = 15
  environment {
    variables = { CORS_ALLOW_ORIGIN = var.cors_allow_origin }
  }
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "${var.name_prefix}-authorizer"
  role             = aws_iam_role.lambda.arn
  runtime          = var.authorizer_lambda_runtime
  handler          = "bootstrap"
  filename         = var.authorizer_zip
  source_code_hash = filebase64sha256(var.authorizer_zip)
  timeout          = 15
  environment {
    variables = {
      FUNCTION_KIND     = "token-authorizer"
      COGNITO_ISSUER    = var.cognito_issuer
      COGNITO_CLIENT_ID = var.cognito_client_id
    }
  }
}

resource "aws_api_gateway_rest_api" "this" {
  name = "${var.name_prefix}-api"
}

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "hello" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "hello"
}

resource "aws_api_gateway_authorizer" "this" {
  name                             = "${var.name_prefix}-token-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  type                             = "TOKEN"
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 0
}

resource "aws_api_gateway_method" "hello_get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "hello" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.hello.id
  http_method             = aws_api_gateway_method.hello_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.hello.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

resource "aws_api_gateway_method" "hello_options" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "hello_options" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.hello.id
  http_method          = aws_api_gateway_method.hello_options.http_method
  type                 = "MOCK"
  timeout_milliseconds = 50

  request_templates = {
    "application/json" = jsonencode({ statusCode = 204 })
  }

  # Floci currently omits request templates when reading the integration.
  lifecycle { ignore_changes = [request_templates] }
}

resource "aws_api_gateway_method_response" "hello_options" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_options.http_method
  status_code = "204"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Vary"                         = true
  }

  # Floci currently omits these fields in get-method-response.
  lifecycle { ignore_changes = [response_parameters] }
}

resource "aws_api_gateway_integration_response" "hello_options" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_options.http_method
  status_code = aws_api_gateway_method_response.hello_options.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "method.response.header.Vary"                         = "'Origin'"
  }

}

resource "aws_api_gateway_gateway_response" "unauthorized" {
  count         = var.enable_gateway_responses ? 1 : 0
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"
  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "gatewayresponse.header.Vary"                         = "'Origin'"
  }
  response_templates = {
    "application/json" = "{\"message\":$context.error.messageString}"
  }
}

resource "aws_api_gateway_gateway_response" "access_denied" {
  count         = var.enable_gateway_responses ? 1 : 0
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "ACCESS_DENIED"
  status_code   = "403"
  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "gatewayresponse.header.Vary"                         = "'Origin'"
  }
  response_templates = {
    "application/json" = "{\"message\":$context.error.messageString}"
  }
}

moved {
  from = aws_api_gateway_gateway_response.unauthorized
  to   = aws_api_gateway_gateway_response.unauthorized[0]
}

moved {
  from = aws_api_gateway_gateway_response.access_denied
  to   = aws_api_gateway_gateway_response.access_denied[0]
}

resource "aws_lambda_permission" "api_hello" {
  statement_id  = "AllowApiGatewayInvokeHello"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_authorizer" {
  statement_id  = "AllowApiGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/${aws_api_gateway_authorizer.this.id}"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  triggers = {
    redeployment = sha1(jsonencode({
      method                           = aws_api_gateway_method.hello_get.id
      integration                      = aws_api_gateway_integration.hello.id
      authorizer                       = aws_api_gateway_authorizer.this.id
      cors_method                      = aws_api_gateway_method.hello_options.id
      cors                             = aws_api_gateway_integration_response.hello_options.id
      integration_timeout_milliseconds = var.integration_timeout_milliseconds
      cors_allow_origin                = var.cors_allow_origin
      unauthorized_gateway_response    = try(aws_api_gateway_gateway_response.unauthorized[0].id, "")
      access_denied_gateway_response   = try(aws_api_gateway_gateway_response.access_denied[0].id, "")
      cognito_issuer                   = var.cognito_issuer
      cognito_client_id                = var.cognito_client_id
    }))
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.stage_name
}
