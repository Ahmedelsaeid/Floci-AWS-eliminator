# Order API: API Gateway (REST) -> Lambda, wired to resources owned by the floci-infra stack.
# The infra stack publishes its resource names in SSM; this stack only reads them,
# so the two pipelines stay independent (no shared Terraform state).

data "aws_ssm_parameter" "infra" {
  for_each = toset(["orders_table", "invoices_bucket", "topic_arn", "lambda_role_arn"])
  name     = "/${var.prefix}/infra/${each.key}"
}

locals {
  infra = { for k, p in data.aws_ssm_parameter.infra : k => p.value }
}

# ---------------- Lambda ----------------
resource "aws_lambda_function" "orders" {
  function_name    = "${var.prefix}-orders-api"
  role             = local.infra["lambda_role_arn"]
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = var.lambda_zip
  source_code_hash = filebase64sha256(var.lambda_zip)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      ORDERS_TABLE     = local.infra["orders_table"]
      INVOICES_BUCKET  = local.infra["invoices_bucket"]
      TOPIC_ARN        = local.infra["topic_arn"]
      APP_AWS_ENDPOINT = var.floci_endpoint # remove on real AWS
    }
  }
}

# ---------------- API Gateway (REST, Lambda proxy) ----------------
resource "aws_api_gateway_rest_api" "orders" {
  name        = "${var.prefix}-orders-api"
  description = "Order service API (deployed by floci-app pipeline)"
}

resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  parent_id   = aws_api_gateway_rest_api.orders.root_resource_id
  path_part   = "orders"
}

resource "aws_api_gateway_resource" "order" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  parent_id   = aws_api_gateway_resource.orders.id
  path_part   = "{orderId}"
}

locals {
  routes = {
    create = { resource_id = aws_api_gateway_resource.orders.id, method = "POST" }
    get    = { resource_id = aws_api_gateway_resource.order.id, method = "GET" }
  }
}

resource "aws_api_gateway_method" "route" {
  for_each      = local.routes
  rest_api_id   = aws_api_gateway_rest_api.orders.id
  resource_id   = each.value.resource_id
  http_method   = each.value.method
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "route" {
  for_each                = local.routes
  rest_api_id             = aws_api_gateway_rest_api.orders.id
  resource_id             = each.value.resource_id
  http_method             = aws_api_gateway_method.route[each.key].http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.orders.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.orders.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id

  # Redeploy whenever routes, integrations or code change
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.orders.id,
      aws_api_gateway_resource.order.id,
      [for m in aws_api_gateway_method.route : m.id],
      [for i in aws_api_gateway_integration.route : i.id],
      aws_lambda_function.orders.source_code_hash,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.route]
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = aws_api_gateway_rest_api.orders.id
  deployment_id = aws_api_gateway_deployment.orders.id
  stage_name    = var.stage
}
