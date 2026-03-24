output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = aws_lambda_function.nr_sync.function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed Lambda function."
  value       = aws_lambda_function.nr_sync.arn
}

output "secrets_manager_secret_name" {
  description = "Secrets Manager secret name holding the New Relic credentials."
  value       = aws_secretsmanager_secret.nr_credentials.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group that receives Lambda execution logs."
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "dlq_url" {
  description = "SQS Dead-Letter Queue URL for monitoring failed Lambda invocations."
  value       = aws_sqs_queue.dlq.url
}

output "ec2_state_change_rule_arn" {
  description = "EventBridge rule ARN for EC2 instance state-change events."
  value       = aws_cloudwatch_event_rule.ec2_state_running.arn
}

output "ec2_tag_change_rule_arn" {
  description = "EventBridge rule ARN for EC2 tag-change events."
  value       = aws_cloudwatch_event_rule.ec2_tag_change.arn
}

output "scheduled_sync_rule_arn" {
  description = "EventBridge rule ARN for the periodic full-sync schedule."
  value       = aws_cloudwatch_event_rule.scheduled_sync.arn
}
