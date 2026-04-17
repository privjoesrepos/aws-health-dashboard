provider "aws" {
  region = "us-east-1"
}

provider "random" {}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "discord_webhook" {
  name            = var.discord_webhook_ssm_name
  with_decryption = true
}

variable "image_tag" {
  description = "The specific image tag to deploy from ECR"
  type        = string
  default     = "latest" # Fallback, but the deploy script will override this
}

# ==========================================
#           ECR REPOSITORY
# ==========================================

resource "aws_ecr_repository" "lambda_image" {
  name                 = "sns-to-chat-alert"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # Auto-scan for vulnerabilities on every push
  }
}

resource "aws_ecr_lifecycle_policy" "lambda_image" {
  repository = aws_ecr_repository.lambda_image.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ==========================================
#           ALERTING PIPELINE
# ==========================================

resource "aws_sns_topic" "health_alerts" {
  name = "infrastructure-health-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.health_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_sns_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allows Lambda to pull the container image from ECR
resource "aws_iam_role_policy_attachment" "lambda_ecr" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# NOTE: In a production environment, this Lambda function should be configured
# with a Dead Letter Queue (DLQ) using an SQS queue. If the Discord Webhook
# fails, SNS would drop the alert silently. A DLQ catches these failed events
# so they aren't lost, and a CloudWatch Alarm on the DLQ would notify us
# that the primary alerting pipeline is broken.

resource "aws_lambda_function" "chat_alert" {
  function_name = "SNS-to-Chat-Alert"
  role          = aws_iam_role.lambda_exec_role.arn

  # Switched from zip to container image deployment.
  # Runtime and handler are now defined inside the Dockerfile CMD directive.
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.lambda_image.repository_url}:${var.image_tag}"
  timeout      = 15

  environment {
    variables = {
      WEBHOOK_URL = data.aws_ssm_parameter.discord_webhook.value
    }
  }
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_alert.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.health_alerts.arn
}

resource "aws_sns_topic_subscription" "lambda_alert" {
  topic_arn = aws_sns_topic.health_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chat_alert.arn
}

# ==========================================
#         DASHBOARD & BILLING ALARM
# ==========================================

resource "aws_cloudwatch_metric_alarm" "high_spend_alert" {
  alarm_name          = "AWS-Billing-Alert"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = "21600"
  statistic           = "Maximum"
  threshold           = "5"
  dimensions = {
    Currency = "USD"
  }
  alarm_actions = [aws_sns_topic.health_alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main_health_dashboard" {
  dashboard_name = "Infrastructure-Health-Dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title  = "💰 AWS Billing Status"
          alarms = [aws_cloudwatch_metric_alarm.high_spend_alert.arn]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "⚡ Lambda Invocations"
          view    = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.chat_alert.function_name, { "stat" : "Sum", "period" : 300, "label" : "Executions" }]
          ]
          region = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "🚨 Lambda Errors"
          view    = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.chat_alert.function_name, { "stat" : "Sum", "period" : 300, "label" : "Errors" }]
          ]
          region = "us-east-1"
        }
      }
    ]
  })
}

# ==========================================
#            CLOUDTRAIL SECURITY
# ==========================================

resource "random_id" "cloudtrail_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "monitor-cloudtrail-s3-${random_id.cloudtrail_bucket_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "CloudTrail/SecurityAudit"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_resource_policy" "cloudtrail" {
  policy_name = "CloudTrailAllowPolicy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "CloudTrailToCloudWatchRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "CloudTrailLogsPolicy"
  role = aws_iam_role.cloudtrail_cloudwatch.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Effect   = "Allow"
      Resource = [aws_cloudwatch_log_group.cloudtrail.arn, "${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
    }]
  })
}

resource "aws_cloudtrail" "security_audit" {
  name                          = "SecurityAuditTrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  cloud_watch_logs_group_arn    = aws_cloudwatch_log_group.cloudtrail.arn
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cloudwatch.arn

  # ARCHITECTURAL NOTE / TECHNICAL DEBT
  # Ideally, Terraform should manage the CloudWatch Logs integration entirely.
  # However, due to a known, global AWS CloudTrail API bug ("InvalidCloudWatchLogsLogGroupArnException"),
  # both the Terraform provider and AWS CLI fail to attach these logs natively.
  # As a workaround, this link was established manually via the AWS Console, and
  # Terraform is instructed to ignore drift on these specific security-critical fields.
  # In a production enterprise environment, this would be paired with an independent
  # automated compliance check to ensure this security link is never silently broken.
  lifecycle {
    ignore_changes = [
      cloud_watch_logs_group_arn,
      cloud_watch_logs_role_arn
    ]
  }
}

resource "aws_cloudwatch_log_metric_filter" "iam_security" {
  name           = "IAMSecurityChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventName = CreateUser) || ($.eventName = DeleteUser) || ($.eventName = CreateAccessKey) || ($.eventName = PutUserPolicy) }"

  metric_transformation {
    name          = "IAMChanges"
    namespace     = "SecurityMetrics"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_security_alert" {
  alarm_name          = "IAM-Security-Alert"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "IAMChanges"
  namespace           = "SecurityMetrics"
  period              = "300"             
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Triggers when a sensitive IAM action is performed."
  alarm_actions       = [aws_sns_topic.health_alerts.arn]
}      WEBHOOK_URL = data.aws_ssm_parameter.discord_webhook.value
    }
  }
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_alert.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.health_alerts.arn
}

resource "aws_sns_topic_subscription" "lambda_alert" {
  topic_arn = aws_sns_topic.health_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chat_alert.arn
}

# ==========================================
#         DASHBOARD & BILLING ALARM
# ==========================================

resource "aws_cloudwatch_metric_alarm" "high_spend_alert" {
  alarm_name          = "AWS-Billing-Alert"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = "21600"
  statistic           = "Maximum"
  threshold           = "5"
  dimensions = {
    Currency = "USD"
  }
  alarm_actions = [aws_sns_topic.health_alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main_health_dashboard" {
  dashboard_name = "Infrastructure-Health-Dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title = "💰 AWS Billing Status"
          alarms = [aws_cloudwatch_metric_alarm.high_spend_alert.arn]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "⚡ Lambda Invocations"
          view    = "timeSeries"
          metrics = [
            [ "AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.chat_alert.function_name, { "stat": "Sum", "period": 300, "label": "Executions" } ]
          ]
          region = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "🚨 Lambda Errors"
          view    = "timeSeries"
          metrics = [
            [ "AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.chat_alert.function_name, { "stat": "Sum", "period": 300, "label": "Errors" } ]
          ]
          region = "us-east-1"
        }
      }
    ]
  })
}

# ==========================================
#            CLOUDTRAIL SECURITY
# ==========================================

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "monitor-cloudtrail-s3-54122" # Change numbers if taken globally
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "CloudTrail/SecurityAudit"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_resource_policy" "cloudtrail" {
  policy_name = "CloudTrailAllowPolicy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "CloudTrailToCloudWatchRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "CloudTrailLogsPolicy"
  role = aws_iam_role.cloudtrail_cloudwatch.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Effect   = "Allow"
      Resource = [aws_cloudwatch_log_group.cloudtrail.arn, "${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
    }]
  })
}

resource "aws_cloudtrail" "security_audit" {
  name                       = "SecurityAuditTrail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail      = true
  cloud_watch_logs_group_arn = aws_cloudwatch_log_group.cloudtrail.arn
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # ARCHITECTURAL NOTE / TECHNICAL DEBT
  # Ideally, Terraform should manage the CloudWatch Logs integration entirely. 
  # However, due to a known, global AWS CloudTrail API bug ("InvalidCloudWatchLogsLogGroupArnException"), 
  # both the Terraform provider and AWS CLI fail to attach these logs natively.
  # As a workaround, this link was established manually via the AWS Console, and 
  # Instructed Terraform to ignore drift on these specific security-critical fields.
  # In a production enterprise environment, this would be paired with an independent 
  # automated compliance check to ensure this security link is never silently broken.
  lifecycle {
    ignore_changes = [
      cloud_watch_logs_group_arn,
      cloud_watch_logs_role_arn
    ]
  }
}

resource "aws_cloudwatch_log_metric_filter" "iam_security" {
  name           = "IAMSecurityChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventName = CreateUser) || ($.eventName = DeleteUser) || ($.eventName = CreateAccessKey) || ($.eventName = PutUserPolicy) }"

  metric_transformation {
    name          = "IAMChanges"
    namespace     = "SecurityMetrics"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_security_alert" {
  alarm_name          = "IAM-Security-Alert"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "IAMChanges"
  namespace           = "SecurityMetrics"
  period              = "300"               # 5 Minutes
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Triggers when a sensitive IAM action is performed."
  alarm_actions       = [aws_sns_topic.health_alerts.arn]
}
