output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.frontend.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.frontend.id
}

output "cognito_domain" {
  value = "${aws_cognito_user_pool_domain.frontend.domain}.auth.${local.config.aws_region}.amazoncognito.com"
}

output "auth_gate_lambda_version_arn" {
  value = aws_lambda_function.frontend_auth_gate.qualified_arn
}
