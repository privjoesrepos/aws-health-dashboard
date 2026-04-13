# variables.tf

variable "alert_email" {
  description = "Email address for SNS billing alerts"
  type        = string
  default     = "*" # YOUR EMAIL
}

variable "discord_webhook_ssm_name" {
  description = "The SSM Parameter Store name holding the encrypted Discord Webhook URL"
  type        = string
  default     = "/health-dashboard/discord-webhook"
}
