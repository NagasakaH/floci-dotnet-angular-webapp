output "rest_api_id" { value = module.api.rest_api_id }
output "stage_name" { value = module.api.stage_name }
output "floci_invoke_url" {
  value = "${var.floci_endpoint}/restapis/${module.api.rest_api_id}/${module.api.stage_name}/_user_request_"
}
