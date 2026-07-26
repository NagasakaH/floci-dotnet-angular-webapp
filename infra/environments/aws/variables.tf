variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}
variable "frontend_origin" {
  type        = string
  description = "CloudFront origin, e.g. https://d111111abcdef8.cloudfront.net (no trailing slash)."
}
