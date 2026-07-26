variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}
variable "floci_endpoint" {
  type    = string
  default = "http://localhost:4566"
}
variable "frontend_origin" {
  type        = string
  description = "Angular dev origin. Production must be its separate CloudFront origin."
  default     = "http://localhost:4200"
}
