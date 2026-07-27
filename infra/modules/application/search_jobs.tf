resource "aws_s3_bucket" "search_results" {
  bucket_prefix = "${var.name_prefix}-search-results-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "search_results" {
  bucket = aws_s3_bucket.search_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "search_results" {
  bucket = aws_s3_bucket.search_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "search_results" {
  bucket = aws_s3_bucket.search_results.id

  rule {
    id     = "expire-temporary-search-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_dynamodb_table" "search_jobs" {
  name         = "${var.name_prefix}-search-jobs"
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

resource "aws_sqs_queue" "search_dead_letter" {
  name                      = "${var.name_prefix}-search-jobs-dlq"
  message_retention_seconds = 345600
}

resource "aws_sqs_queue" "search_jobs" {
  name                       = "${var.name_prefix}-search-jobs"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.search_dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_iam_role" "search_api" {
  name               = "${var.name_prefix}-search-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role" "search_worker" {
  name               = "${var.name_prefix}-search-worker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "search_api" {
  name = "${var.name_prefix}-search-api"
  role = aws_iam_role.search_api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.search_jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.search_jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.search_results.arn}/results/*"
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

resource "aws_iam_role_policy" "search_worker" {
  name = "${var.name_prefix}-search-worker"
  role = aws_iam_role.search_worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.search_jobs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ]
        Resource = aws_sqs_queue.search_jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.search_results.arn}/results/*"
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

locals {
  search_environment = {
    CORS_ALLOW_ORIGIN = var.cors_allow_origin
    SEARCH_JOBS_TABLE = aws_dynamodb_table.search_jobs.name
    SEARCH_QUEUE_URL = var.aws_service_endpoint == "" ? aws_sqs_queue.search_jobs.url : replace(
      aws_sqs_queue.search_jobs.url,
      var.public_s3_endpoint,
      var.aws_service_endpoint
    )
    SEARCH_RESULTS_BUCKET = aws_s3_bucket.search_results.id
    AWS_SERVICE_ENDPOINT  = var.aws_service_endpoint
    PUBLIC_S3_ENDPOINT    = var.public_s3_endpoint
  }
}

resource "aws_lambda_function" "search_api" {
  function_name    = "${var.name_prefix}-search-api"
  role             = aws_iam_role.search_api.arn
  runtime          = var.hello_lambda_runtime
  handler          = "SearchJobs::SearchJobs.ApiFunction::Handler"
  filename         = var.search_jobs_zip
  source_code_hash = filebase64sha256(var.search_jobs_zip)
  timeout          = 15
  memory_size      = 256

  environment {
    variables = local.search_environment
  }
}

resource "aws_lambda_function" "search_worker" {
  function_name    = "${var.name_prefix}-search-worker"
  role             = aws_iam_role.search_worker.arn
  runtime          = var.hello_lambda_runtime
  handler          = "SearchJobs::SearchJobs.SearchWorker::Handler"
  filename         = var.search_jobs_zip
  source_code_hash = filebase64sha256(var.search_jobs_zip)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = local.search_environment
  }
}

resource "aws_lambda_event_source_mapping" "search_worker" {
  event_source_arn = aws_sqs_queue.search_jobs.arn
  function_name    = aws_lambda_function.search_worker.arn
  batch_size       = 1
  enabled          = true

  depends_on = [aws_iam_role_policy.search_worker]
}

resource "aws_api_gateway_resource" "search_jobs" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "search-jobs"
}

resource "aws_api_gateway_resource" "search_job" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.search_jobs.id
  path_part   = "{jobId}"
}

resource "aws_api_gateway_method" "search_start" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.search_jobs.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "search_start" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.search_jobs.id
  http_method             = aws_api_gateway_method.search_start.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.search_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

resource "aws_api_gateway_method" "search_status" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.search_job.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "search_status" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.search_job.id
  http_method             = aws_api_gateway_method.search_status.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.search_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

locals {
  search_cors_resources = {
    collection = aws_api_gateway_resource.search_jobs.id
    item       = aws_api_gateway_resource.search_job.id
  }
}

resource "aws_api_gateway_method" "search_options" {
  for_each = local.search_cors_resources

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "search_options" {
  for_each = local.search_cors_resources

  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = each.value
  http_method          = aws_api_gateway_method.search_options[each.key].http_method
  type                 = "MOCK"
  timeout_milliseconds = 50

  request_templates = {
    "application/json" = jsonencode({ statusCode = 204 })
  }

  lifecycle { ignore_changes = [request_templates] }
}

resource "aws_api_gateway_method_response" "search_options" {
  for_each = local.search_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.search_options[each.key].http_method
  status_code = "204"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Vary"                         = true
  }

  lifecycle { ignore_changes = [response_parameters] }
}

resource "aws_api_gateway_integration_response" "search_options" {
  for_each = local.search_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.search_options[each.key].http_method
  status_code = aws_api_gateway_method_response.search_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "method.response.header.Vary"                         = "'Origin'"
  }
}

resource "aws_lambda_permission" "api_search" {
  statement_id  = "AllowApiGatewayInvokeSearch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.search_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
