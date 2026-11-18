output "api_id" {
  value = aws_api_gateway_rest_api.orders.id
}

# Floci's REST API invoke URL format. On real AWS use aws_api_gateway_stage.stage.invoke_url
output "invoke_url" {
  value = "${var.floci_endpoint}/restapis/${aws_api_gateway_rest_api.orders.id}/${aws_api_gateway_stage.stage.stage_name}/_user_request_"
}

output "invoke_url_from_vm" {
  description = "Same URL, usable from the VM shell or Windows (replace localhost with the VM IP)"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.orders.id}/${aws_api_gateway_stage.stage.stage_name}/_user_request_"
}

output "function_name" {
  value = aws_lambda_function.orders.function_name
}
