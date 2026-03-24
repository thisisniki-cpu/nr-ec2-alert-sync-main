# ---------------------------------------------------------------------------
# Rule 1 — EC2 instance enters 'running' state
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "ec2_state_running" {
  name        = "${local.function_name}-ec2-running"
  description = "Invoke Lambda when an EC2 instance enters the 'running' state."

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["running"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ec2_state_running" {
  rule = aws_cloudwatch_event_rule.ec2_state_running.name
  arn  = aws_lambda_function.nr_sync.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "ec2_state_running" {
  statement_id  = "AllowEventBridgeEC2StateRunning"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nr_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_state_running.arn
}

# ---------------------------------------------------------------------------
# Rule 2 — 'application' tag added or changed on an EC2 instance
#
# Handles the case where an instance is launched without tags and the tag
# is applied afterwards (common in automation pipelines).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "ec2_tag_change" {
  name        = "${local.function_name}-ec2-tag-change"
  description = "Invoke Lambda when the 'application' tag changes on an EC2 instance."

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    "detail-type" = ["Tag Change on Resource"]
    detail = {
      service          = ["ec2"]
      "resource-type"  = ["instance"]
      "changed-tag-keys" = ["application"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ec2_tag_change" {
  rule = aws_cloudwatch_event_rule.ec2_tag_change.name
  arn  = aws_lambda_function.nr_sync.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "ec2_tag_change" {
  statement_id  = "AllowEventBridgeEC2TagChange"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nr_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_tag_change.arn
}

# ---------------------------------------------------------------------------
# Rule 3 — Scheduled full-sync (hourly safety net)
#
# Catches anything the event-driven rules might have missed: instances
# launched before this solution was deployed, manually tagged instances,
# eventual-consistency gaps, etc.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "scheduled_sync" {
  name                = "${local.function_name}-scheduled-sync"
  description         = "Periodic full-sync of all EC2 'application' tags to New Relic."
  schedule_expression = var.sync_schedule
}

resource "aws_cloudwatch_event_target" "scheduled_sync" {
  rule = aws_cloudwatch_event_rule.scheduled_sync.name
  arn  = aws_lambda_function.nr_sync.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "scheduled_sync" {
  statement_id  = "AllowEventBridgeScheduledSync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nr_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduled_sync.arn
}
