resource "aws_dynamodb_table" "workflow_jobs" {
  name         = "${var.name_prefix}-workflow-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "jobId"

  attribute {
    name = "jobId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

resource "aws_iam_role" "workflow_api" {
  name               = "${var.name_prefix}-workflow-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "workflow_api" {
  name = "${var.name_prefix}-workflow-api"
  role = aws_iam_role.workflow_api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.workflow_jobs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "states:StartExecution"
        ]
        Resource = aws_sfn_state_machine.request_workflow.arn
      },
      {
        Effect = "Allow"
        Action = [
          "states:DescribeExecution",
          "states:GetExecutionHistory"
        ]
        Resource = "${replace(aws_sfn_state_machine.request_workflow.arn, ":stateMachine:", ":execution:")}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

data "aws_iam_policy_document" "step_functions_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workflow_state_machine" {
  name               = "${var.name_prefix}-workflow-state-machine"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume.json
}

resource "aws_iam_role_policy" "workflow_state_machine" {
  name = "${var.name_prefix}-workflow-state-machine"
  role = aws_iam_role.workflow_state_machine.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.workflow_validate.arn,
        aws_lambda_function.workflow_process.arn
      ]
    }]
  })
}

locals {
  workflow_environment = {
    CORS_ALLOW_ORIGIN          = var.cors_allow_origin
    WORKFLOW_JOBS_TABLE        = aws_dynamodb_table.workflow_jobs.name
    WORKFLOW_STATE_MACHINE_ARN = aws_sfn_state_machine.request_workflow.arn
    AWS_SERVICE_ENDPOINT       = var.aws_service_endpoint
  }
}

resource "aws_lambda_function" "workflow_validate" {
  function_name    = "${var.name_prefix}-workflow-validate"
  role             = aws_iam_role.lambda.arn
  runtime          = var.hello_lambda_runtime
  handler          = "WorkflowJobs::WorkflowJobs.ValidateTask::Handler"
  filename         = var.workflow_jobs_zip
  source_code_hash = filebase64sha256(var.workflow_jobs_zip)
  timeout          = 15
  memory_size      = 256
}

resource "aws_lambda_function" "workflow_process" {
  function_name    = "${var.name_prefix}-workflow-process"
  role             = aws_iam_role.lambda.arn
  runtime          = var.hello_lambda_runtime
  handler          = "WorkflowJobs::WorkflowJobs.ProcessTask::Handler"
  filename         = var.workflow_jobs_zip
  source_code_hash = filebase64sha256(var.workflow_jobs_zip)
  timeout          = 15
  memory_size      = 256
}

resource "aws_sfn_state_machine" "request_workflow" {
  name     = "${var.name_prefix}-request-workflow"
  role_arn = aws_iam_role.workflow_state_machine.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Validated request workflow with Choice, Wait, Retry and Lambda Task examples"
    StartAt = "ValidateRequest"
    States = {
      ValidateRequest = {
        Type       = "Task"
        Resource   = aws_lambda_function.workflow_validate.arn
        ResultPath = "$"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 1
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "WorkflowFailed"
        }]
        Next = "RouteRequest"
      }
      RouteRequest = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.validation.requiresReview"
          BooleanEquals = true
          Next          = "ReviewDelay"
        }]
        Default = "FastTrackRoute"
      }
      ReviewDelay = {
        Type    = "Wait"
        Seconds = 2
        Next    = "ManualReviewRoute"
      }
      ManualReviewRoute = {
        Type = "Pass"
        Result = {
          lane         = "MANUAL_REVIEW"
          delaySeconds = 2
        }
        ResultPath = "$.route"
        Next       = "ProcessRequest"
      }
      FastTrackRoute = {
        Type = "Pass"
        Result = {
          lane         = "FAST_TRACK"
          delaySeconds = 0
        }
        ResultPath = "$.route"
        Next       = "ProcessRequest"
      }
      ProcessRequest = {
        Type     = "Task"
        Resource = aws_lambda_function.workflow_process.arn
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 1
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "WorkflowFailed"
        }]
        End = true
      }
      WorkflowFailed = {
        Type  = "Fail"
        Error = "WorkflowTaskFailed"
        Cause = "A workflow Lambda task failed after retries."
      }
    }
  })

  depends_on = [aws_iam_role_policy.workflow_state_machine]
}

resource "aws_lambda_function" "workflow_api" {
  function_name    = "${var.name_prefix}-workflow-api"
  role             = aws_iam_role.workflow_api.arn
  runtime          = var.hello_lambda_runtime
  handler          = "WorkflowJobs::WorkflowJobs.ApiFunction::Handler"
  filename         = var.workflow_jobs_zip
  source_code_hash = filebase64sha256(var.workflow_jobs_zip)
  timeout          = 15
  memory_size      = 256

  environment {
    variables = local.workflow_environment
  }
}

resource "aws_api_gateway_resource" "workflow_jobs" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "workflow-jobs"
}

resource "aws_api_gateway_resource" "workflow_job" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.workflow_jobs.id
  path_part   = "{jobId}"
}

resource "aws_api_gateway_method" "workflow_start" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.workflow_jobs.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "workflow_start" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.workflow_jobs.id
  http_method             = aws_api_gateway_method.workflow_start.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.workflow_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

resource "aws_api_gateway_method" "workflow_status" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.workflow_job.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "workflow_status" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.workflow_job.id
  http_method             = aws_api_gateway_method.workflow_status.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.workflow_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

locals {
  workflow_cors_resources = {
    collection = aws_api_gateway_resource.workflow_jobs.id
    item       = aws_api_gateway_resource.workflow_job.id
  }
}

resource "aws_api_gateway_method" "workflow_options" {
  for_each = local.workflow_cors_resources

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "workflow_options" {
  for_each = local.workflow_cors_resources

  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = each.value
  http_method          = aws_api_gateway_method.workflow_options[each.key].http_method
  type                 = "MOCK"
  timeout_milliseconds = 50

  request_templates = {
    "application/json" = jsonencode({ statusCode = 204 })
  }

  lifecycle { ignore_changes = [request_templates] }
}

resource "aws_api_gateway_method_response" "workflow_options" {
  for_each = local.workflow_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.workflow_options[each.key].http_method
  status_code = "204"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Vary"                         = true
  }

  lifecycle { ignore_changes = [response_parameters] }
}

resource "aws_api_gateway_integration_response" "workflow_options" {
  for_each = local.workflow_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.workflow_options[each.key].http_method
  status_code = aws_api_gateway_method_response.workflow_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "method.response.header.Vary"                         = "'Origin'"
  }
}

resource "aws_lambda_permission" "api_workflow" {
  statement_id  = "AllowApiGatewayInvokeWorkflow"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.workflow_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
