resource "aws_s3_bucket" "file_ingest" {
  bucket_prefix = "${var.name_prefix}-file-ingest-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "file_ingest" {
  bucket = aws_s3_bucket.file_ingest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "file_ingest" {
  bucket = aws_s3_bucket.file_ingest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "file_ingest" {
  bucket = aws_s3_bucket.file_ingest.id

  cors_rule {
    allowed_headers = ["Content-Type"]
    allowed_methods = ["PUT"]
    allowed_origins = [var.cors_allow_origin]
    expose_headers  = ["ETag"]
    max_age_seconds = 300
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "file_ingest" {
  bucket = aws_s3_bucket.file_ingest.id

  rule {
    id     = "expire-temporary-file-ingest-data"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_dynamodb_table" "file_jobs" {
  name         = "${var.name_prefix}-file-jobs"
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

resource "aws_sqs_queue" "file_ingest_dead_letter" {
  name                      = "${var.name_prefix}-file-ingest-dlq"
  message_retention_seconds = 345600
}

resource "aws_sqs_queue" "file_ingest_events" {
  name                       = "${var.name_prefix}-file-ingest-events"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.file_ingest_dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "file_ingest_events" {
  queue_url = aws_sqs_queue.file_ingest_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3EventNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.file_ingest_events.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_s3_bucket.file_ingest.arn
        }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "file_ingest" {
  bucket = aws_s3_bucket.file_ingest.id

  queue {
    queue_arn     = aws_sqs_queue.file_ingest_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sqs_queue_policy.file_ingest_events]
}

resource "aws_iam_role" "file_api" {
  name               = "${var.name_prefix}-file-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role" "file_processor" {
  name               = "${var.name_prefix}-file-processor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "file_api" {
  name = "${var.name_prefix}-file-api"
  role = aws_iam_role.file_api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.file_jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.file_ingest.arn}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.file_ingest.arn}/reports/*"
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

resource "aws_iam_role_policy" "file_processor" {
  name = "${var.name_prefix}-file-processor"
  role = aws_iam_role.file_processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.file_jobs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ]
        Resource = aws_sqs_queue.file_ingest_events.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.file_ingest.arn}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.file_ingest.arn}/reports/*"
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
  file_ingest_environment = {
    CORS_ALLOW_ORIGIN    = var.cors_allow_origin
    FILE_JOBS_TABLE      = aws_dynamodb_table.file_jobs.name
    FILE_INGEST_BUCKET   = aws_s3_bucket.file_ingest.id
    AWS_SERVICE_ENDPOINT = var.aws_service_endpoint
    PUBLIC_S3_ENDPOINT   = var.public_s3_endpoint
  }
}

resource "aws_lambda_function" "file_api" {
  function_name    = "${var.name_prefix}-file-api"
  role             = aws_iam_role.file_api.arn
  runtime          = var.hello_lambda_runtime
  handler          = "FileIngest::FileIngest.ApiFunction::Handler"
  filename         = var.file_ingest_zip
  source_code_hash = filebase64sha256(var.file_ingest_zip)
  timeout          = 15
  memory_size      = 256

  environment {
    variables = local.file_ingest_environment
  }
}

resource "aws_lambda_function" "file_processor" {
  function_name    = "${var.name_prefix}-file-processor"
  role             = aws_iam_role.file_processor.arn
  runtime          = var.hello_lambda_runtime
  handler          = "FileIngest::FileIngest.FileProcessor::Handler"
  filename         = var.file_ingest_zip
  source_code_hash = filebase64sha256(var.file_ingest_zip)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = local.file_ingest_environment
  }
}

resource "aws_lambda_event_source_mapping" "file_processor" {
  event_source_arn = aws_sqs_queue.file_ingest_events.arn
  function_name    = aws_lambda_function.file_processor.arn
  batch_size       = 1
  enabled          = true

  depends_on = [aws_iam_role_policy.file_processor]
}

resource "aws_api_gateway_resource" "file_jobs" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "file-jobs"
}

resource "aws_api_gateway_resource" "file_job" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.file_jobs.id
  path_part   = "{jobId}"
}

resource "aws_api_gateway_method" "file_start" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.file_jobs.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "file_start" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.file_jobs.id
  http_method             = aws_api_gateway_method.file_start.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.file_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

resource "aws_api_gateway_method" "file_status" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.file_job.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this.id
}

resource "aws_api_gateway_integration" "file_status" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.file_job.id
  http_method             = aws_api_gateway_method.file_status.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.file_api.invoke_arn
  timeout_milliseconds    = var.integration_timeout_milliseconds
}

locals {
  file_cors_resources = {
    collection = aws_api_gateway_resource.file_jobs.id
    item       = aws_api_gateway_resource.file_job.id
  }
}

resource "aws_api_gateway_method" "file_options" {
  for_each = local.file_cors_resources

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "file_options" {
  for_each = local.file_cors_resources

  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = each.value
  http_method          = aws_api_gateway_method.file_options[each.key].http_method
  type                 = "MOCK"
  timeout_milliseconds = 50

  request_templates = {
    "application/json" = jsonencode({ statusCode = 204 })
  }

  lifecycle { ignore_changes = [request_templates] }
}

resource "aws_api_gateway_method_response" "file_options" {
  for_each = local.file_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.file_options[each.key].http_method
  status_code = "204"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Vary"                         = true
  }

  lifecycle { ignore_changes = [response_parameters] }
}

resource "aws_api_gateway_integration_response" "file_options" {
  for_each = local.file_cors_resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value
  http_method = aws_api_gateway_method.file_options[each.key].http_method
  status_code = aws_api_gateway_method_response.file_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.cors_allow_origin}'"
    "method.response.header.Vary"                         = "'Origin'"
  }
}

resource "aws_lambda_permission" "api_file" {
  statement_id  = "AllowApiGatewayInvokeFile"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
