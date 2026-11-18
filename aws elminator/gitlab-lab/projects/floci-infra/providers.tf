terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is stored in GitLab (Operate -> Terraform states).
  # The pipeline passes the address and credentials via TF_HTTP_* variables.
  backend "http" {}
}

# Point the real AWS provider at Floci instead of AWS.
# To target real AWS later: delete the endpoints block and the skip_* / dummy keys.
provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3             = var.floci_endpoint
    dynamodb       = var.floci_endpoint
    sns            = var.floci_endpoint
    sqs            = var.floci_endpoint
    iam            = var.floci_endpoint
    sts            = var.floci_endpoint
    ssm            = var.floci_endpoint
    lambda         = var.floci_endpoint
    apigateway     = var.floci_endpoint
    cloudwatchlogs = var.floci_endpoint
  }

  default_tags {
    tags = {
      Project   = "floci-lab"
      Stack     = "infra"
      ManagedBy = "terraform"
    }
  }
}
