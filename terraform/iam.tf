# ---------------------------------------------------------------------------
# Lambda execution role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.function_name}-role"
  description        = "Execution role for the ${local.function_name} Lambda function."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# ---------------------------------------------------------------------------
# Least-privilege policy
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_policy" {

  # CloudWatch Logs — scoped to the function's own log group
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda_logs.arn}:*"]
  }

  # EC2 read — Describe* actions only accept "*" as the resource
  statement {
    sid    = "EC2DescribeInstances"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  # Secrets Manager — scoped to this function's secret only
  statement {
    sid    = "SecretsManagerGetSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.nr_credentials.arn]
  }

  # SQS DLQ — Lambda needs SendMessage to deliver failed-event payloads
  statement {
    sid    = "SQSSendMessageDLQ"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "${local.function_name}-policy"
  description = "Least-privilege policy for the ${local.function_name} Lambda function."
  policy      = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}
