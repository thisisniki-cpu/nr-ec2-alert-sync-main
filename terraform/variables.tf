variable "aws_region" {
  description = "AWS region where all resources are deployed."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for resource names."
  type        = string
  default     = "nr-ec2-alert-sync"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "log_level" {
  description = "Python log level for the Lambda function (DEBUG | INFO | WARNING | ERROR)."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of: DEBUG, INFO, WARNING, ERROR."
  }
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds."
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Lambda function memory in MB."
  type        = number
  default     = 128
}

variable "log_retention_days" {
  description = "CloudWatch Log Group retention period in days."
  type        = number
  default     = 30
}

variable "sync_schedule" {
  description = "EventBridge schedule expression for the periodic full-sync run."
  type        = string
  default     = "rate(1 hour)"
}

variable "dlq_message_retention_seconds" {
  description = "How long (seconds) the DLQ retains failed event messages."
  type        = number
  default     = 1209600 # 14 days
}

variable "nr_api_key" {
  description = <<-EOT
    New Relic User API key (NRAK-...) used to authenticate against NerdGraph.
    Stored in Secrets Manager. Supply here to bootstrap; rotate via Secrets
    Manager afterwards so Terraform does not track the live value.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "nr_account_id" {
  description = "New Relic account ID (numeric string, e.g. '1234567')."
  type        = string
  default     = ""
}
