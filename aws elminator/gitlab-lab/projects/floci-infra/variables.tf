variable "floci_endpoint" {
  description = "Floci endpoint. In CI jobs it is the container name on floci-net."
  type        = string
  default     = "http://floci:4566"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  description = "Name prefix for every resource (lets several environments share one Floci)."
  type        = string
  default     = "lab"
}

variable "consumer_queues" {
  description = "One SQS queue (with its own DLQ) is created per consumer and subscribed to the order-events topic."
  type        = set(string)
  default     = ["billing", "shipping"]
}
