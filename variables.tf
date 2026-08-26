variable "localstack_endpoint" {
  description = "LocalStack endpoint - localhost from the host, localstack-main from Jenkins"
  type        = string
  default     = "http://localhost:4566"
}
