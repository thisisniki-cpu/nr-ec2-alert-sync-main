# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------
locals {
  function_name = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Lambda deployment package (pure-stdlib handler — no pip install needed)
# ---------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/../lambda/handler.zip"
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group  (pre-created so retention is applied from day one)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# SQS Dead-Letter Queue  (captures events Lambda failed to process)
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.function_name}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds

  # Encrypt at rest with the AWS-managed SQS key
  sqs_managed_sse_enabled = true
}

# ---------------------------------------------------------------------------
# Secrets Manager — New Relic credentials
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "nr_credentials" {
  name                    = "${local.function_name}/nr-credentials"
  description             = "New Relic API key and account ID for ${local.function_name}."
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "nr_credentials" {
  secret_id = aws_secretsmanager_secret.nr_credentials.id
  secret_string = jsonencode({
    nr_api_key    = var.nr_api_key
    nr_account_id = var.nr_account_id
  })

  # Allow the secret value to be rotated / updated outside of Terraform
  # without triggering a plan diff on every run.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Lambda Function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "nr_sync" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = local.function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  description      = "Syncs EC2 'application' tags to New Relic Alert Policies."

  environment {
    variables = {
      NR_SECRET_NAME = aws_secretsmanager_secret.nr_credentials.name
      LOG_LEVEL      = var.log_level
    }
  }

  # Ensure the log group and role exist before creating the function
  depends_on = [
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy_attachment.lambda_policy,
  ]
}

# ---------------------------------------------------------------------------
# Lambda async invocation config — retry + DLQ for failed async calls
# ---------------------------------------------------------------------------
resource "aws_lambda_function_event_invoke_config" "nr_sync" {
  function_name          = aws_lambda_function.nr_sync.function_name
  maximum_retry_attempts = 2

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}
