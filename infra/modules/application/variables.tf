variable "name_prefix" { type = string }
variable "hello_lambda_runtime" {
  type    = string
  default = "dotnet8"
}
variable "authorizer_lambda_runtime" {
  type    = string
  default = "provided.al2023"
}
variable "hello_zip" { type = string }
variable "authorizer_zip" { type = string }
variable "search_jobs_zip" { type = string }
variable "file_ingest_zip" { type = string }
variable "cors_allow_origin" {
  type        = string
  description = "Exact CloudFront/Angular origin. Use * only for local PoC."
}
variable "stage_name" {
  type    = string
  default = "local"
}
variable "integration_timeout_milliseconds" {
  type        = number
  description = "API Gateway Lambda integration timeout. Floci uses its minimum value; AWS needs enough time for Lambda cold starts."
  default     = 29000
}
variable "cognito_issuer" {
  type        = string
  description = "Cognito issuer trusted by the Authorizer. Empty enables local tokens only."
  default     = ""
}
variable "cognito_client_id" {
  type        = string
  description = "Cognito app client ID trusted by the Authorizer. Empty enables local tokens only."
  default     = ""
}
variable "enable_gateway_responses" {
  type        = bool
  description = "Create API Gateway UNAUTHORIZED/ACCESS_DENIED responses. Disable for emulators that do not implement PutGatewayResponse."
  default     = true
}
variable "aws_service_endpoint" {
  type        = string
  description = "AWS-compatible endpoint reachable from Lambda containers. Empty uses AWS."
  default     = ""
}
variable "public_s3_endpoint" {
  type        = string
  description = "S3 endpoint embedded in local presigned URLs. Empty uses the AWS S3 endpoint."
  default     = ""
}
