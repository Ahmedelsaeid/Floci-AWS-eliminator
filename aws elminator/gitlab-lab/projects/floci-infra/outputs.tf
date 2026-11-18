output "orders_table" {
  value = aws_dynamodb_table.orders.name
}

output "invoices_bucket" {
  value = aws_s3_bucket.invoices.bucket
}

output "topic_arn" {
  value = aws_sns_topic.order_events.arn
}

output "queues" {
  value = { for k, q in aws_sqs_queue.consumer : k => q.name }
}

output "lambda_role_arn" {
  value = aws_iam_role.app_lambda.arn
}

output "ssm_exports" {
  description = "Parameters other stacks read with data \"aws_ssm_parameter\""
  value       = sort([for p in aws_ssm_parameter.exports : p.name])
}
