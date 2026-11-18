# Shared platform for the order system:
#   S3 (invoices) · DynamoDB (orders) · SNS (order-events) -> SQS per consumer (+DLQ)
#   IAM role for the app Lambda · SSM parameters that publish all names to other stacks

# ---------------- Storage ----------------
resource "aws_s3_bucket" "invoices" {
  bucket        = "${var.prefix}-invoices"
  force_destroy = true # lab only: lets `terraform destroy` remove a non-empty bucket
}

resource "aws_s3_bucket_versioning" "invoices" {
  bucket = aws_s3_bucket.invoices.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "orders" {
  name         = "${var.prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
}

# ---------------- Messaging: SNS fan-out to SQS ----------------
resource "aws_sns_topic" "order_events" {
  name = "${var.prefix}-order-events"
}

resource "aws_sqs_queue" "dlq" {
  for_each = var.consumer_queues
  name     = "${var.prefix}-${each.key}-dlq"
}

resource "aws_sqs_queue" "consumer" {
  for_each                   = var.consumer_queues
  name                       = "${var.prefix}-${each.key}"
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "allow_sns" {
  for_each  = var.consumer_queues
  queue_url = aws_sqs_queue.consumer[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.consumer[each.key].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.order_events.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "consumer" {
  for_each             = var.consumer_queues
  topic_arn            = aws_sns_topic.order_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true
}

# ---------------- IAM role for the app Lambda ----------------
resource "aws_iam_role" "app_lambda" {
  name = "${var.prefix}-app-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_lambda" {
  name = "${var.prefix}-app-lambda"
  role = aws_iam_role.app_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:GetItem"], Resource = aws_dynamodb_table.orders.arn },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.order_events.arn },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.invoices.arn}/*" },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
    ]
  })
}

# ---------------- Publish names for other stacks (the app reads these) ----------------
locals {
  exports = merge(
    {
      orders_table    = aws_dynamodb_table.orders.name
      invoices_bucket = aws_s3_bucket.invoices.bucket
      topic_arn       = aws_sns_topic.order_events.arn
      lambda_role_arn = aws_iam_role.app_lambda.arn
    },
    { for k, q in aws_sqs_queue.consumer : "${k}_queue_name" => q.name }
  )
}

resource "aws_ssm_parameter" "exports" {
  for_each = local.exports
  name     = "/${var.prefix}/infra/${each.key}"
  type     = "String"
  value    = each.value
}
