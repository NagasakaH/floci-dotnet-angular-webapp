output "rest_api_id" { value = aws_api_gateway_rest_api.this.id }
output "stage_name" { value = aws_api_gateway_stage.this.stage_name }
output "aws_invoke_url" {
  value = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}"
}

data "aws_region" "current" {}

output "search_results_bucket" {
  value = aws_s3_bucket.search_results.id
}

output "search_jobs_table" {
  value = aws_dynamodb_table.search_jobs.name
}

output "file_ingest_bucket" {
  value = aws_s3_bucket.file_ingest.id
}

output "file_jobs_table" {
  value = aws_dynamodb_table.file_jobs.name
}

output "workflow_jobs_table" {
  value = aws_dynamodb_table.workflow_jobs.name
}

output "workflow_state_machine_arn" {
  value = aws_sfn_state_machine.request_workflow.arn
}
