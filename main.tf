terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State lives in LocalStack S3 so the MacBook and Jenkins share one
  # source of truth. The endpoint comes from AWS_ENDPOINT_URL_S3 because
  # backend blocks cannot use variables.
  backend "s3" {
    bucket                      = "homelab-tfstate"
    key                         = "localstack-demo/terraform.tfstate"
    region                      = "us-east-1"
    access_key                  = "test"
    secret_key                  = "test"
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
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
    kms            = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Customer-managed KMS key. Used by S3, DynamoDB and SQS.
# A CMK (not an AWS-managed key) is what lets you control rotation,
# revoke access, and audit every use in CloudTrail.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "lab" {
  description             = "Homelab CMK for S3, DynamoDB and SQS"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowServiceUse"
        Effect = "Allow"
        Principal = {
          Service = [
            "s3.amazonaws.com",
            "dynamodb.amazonaws.com",
            "sqs.amazonaws.com",
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Environment = "lab"
  }
}

resource "aws_kms_alias" "lab" {
  name          = "alias/homelab"
  target_key_id = aws_kms_key.lab.key_id
}

# ---------------------------------------------------------------------------
# Access-log destination bucket.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:This bucket IS the access-log destination. Pointing its own logging at itself creates a recursive write loop.
  #checkov:skip=CKV_AWS_145:AWS S3 server access log delivery does not support SSE-KMS on the destination bucket. SSE-S3 is required here.
  #checkov:skip=CKV_AWS_144:Single-region lab. Cross-region replication has no second region to target.
  #checkov:skip=CKV2_AWS_62:A log destination bucket has no downstream event consumer.
  bucket = "homelab-access-logs"

  tags = {
    Environment = "lab"
    Purpose     = "s3-access-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132 S3 access-log delivery does not support SSE-KMS; AWS requires SSE-S3 on the destination bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Grants the S3 log-delivery service permission to write into the log bucket.
# Scoped to one source bucket and this account so no other bucket can write here.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "S3ServerAccessLogsPolicy"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.app_data.arn }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---------------------------------------------------------------------------
# Application data bucket.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "app_data" {
  #checkov:skip=CKV_AWS_144:Single-region lab. Cross-region replication doubles storage cost with no second region to fail over to.
  #checkov:skip=CKV2_AWS_62:No event consumer exists yet. Revisit when a Lambda or SQS consumer is attached.
  bucket = "homelab-app-data"

  tags = {
    Environment = "lab"
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket                  = aws_s3_bucket.app_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lab.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "app_data" {
  bucket        = aws_s3_bucket.app_data.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access-logs/homelab-app-data/"
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "sessions" {
  name         = "homelab-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lab.arn
  }

  tags = {
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------
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
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.app_data.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.lab.arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "jobs" {
  name                              = "homelab-jobs"
  kms_master_key_id                 = aws_kms_key.lab.arn
  kms_data_key_reuse_period_seconds = 300
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "bucket_name" { value = aws_s3_bucket.app_data.bucket }
output "logs_bucket" { value = aws_s3_bucket.logs.bucket }
output "table_name" { value = aws_dynamodb_table.sessions.name }
output "role_arn" { value = aws_iam_role.app.arn }
output "queue_url" { value = aws_sqs_queue.jobs.url }
output "kms_key_arn" { value = aws_kms_key.lab.arn }


# Deny any request to app_data that does not arrive over TLS.
resource "aws_s3_bucket_policy" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.app_data.arn,
        "${aws_s3_bucket.app_data.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.app_data]
}
