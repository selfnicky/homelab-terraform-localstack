terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3             = var.localstack_endpoint
    dynamodb       = var.localstack_endpoint
    iam            = var.localstack_endpoint
    sts            = var.localstack_endpoint
    sqs            = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
  }
}

resource "aws_s3_bucket" "app_data" {
  bucket = "homelab-app-data"
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "sessions" {
  name         = "homelab-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  tags = {
    Environment = "lab"
  }
}

resource "aws_iam_role" "app" {
  name = "homelab-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_s3" {
  name = "homelab-app-s3"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "${aws_s3_bucket.app_data.arn}/*"
    }]
  })
}

resource "aws_sqs_queue" "jobs" {
  name = "homelab-jobs"
}

output "bucket_name"  { value = aws_s3_bucket.app_data.bucket }
output "table_name"   { value = aws_dynamodb_table.sessions.name }
output "role_arn"     { value = aws_iam_role.app.arn }
output "queue_url"    { value = aws_sqs_queue.jobs.url }
