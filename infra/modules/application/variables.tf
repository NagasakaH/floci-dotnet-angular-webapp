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
