output "rest_api_id" { value = module.application.rest_api_id }
output "stage_name" { value = module.application.stage_name }
output "floci_invoke_url" {
  value = "${local.config.floci_endpoint}/restapis/${module.application.rest_api_id}/${module.application.stage_name}/_user_request_"
}
