variable "floci_endpoint" {
  type    = string
  default = "http://floci:4566"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  description = "Must match the infra stack prefix (used to find its SSM exports)."
  type        = string
  default     = "lab"
}

variable "stage" {
  type    = string
  default = "dev"
}

variable "lambda_zip" {
  description = "Built by the pipeline's build job."
  type        = string
  default     = "../dist/lambda.zip"
}
