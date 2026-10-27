################################################################################
# Alerts: EventBridge -> SNS when the job ends badly or the crawler fails.
# No duration alarm is needed: job_timeout is explicit, so a stuck run ends in
# TIMEOUT and this rule catches it.
################################################################################

locals {
  create_alerts = var.alerts_sns_topic_arn != null
}

resource "aws_cloudwatch_event_rule" "job_failed" {
  count = local.create_alerts ? 1 : 0

  name        = "${var.name}-job-failed"
  description = "Glue job ${var.name} ended in FAILED, TIMEOUT or ERROR"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.this.name]
      state   = ["FAILED", "TIMEOUT", "ERROR"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "job_failed" {
  count = local.create_alerts ? 1 : 0

  rule = aws_cloudwatch_event_rule.job_failed[0].name
  arn  = var.alerts_sns_topic_arn

  # The error message is left out on purpose: it often contains quotes that
  # break the JSON template.
  input_transformer {
    input_paths = {
      job   = "$.detail.jobName"
      run   = "$.detail.jobRunId"
      state = "$.detail.state"
      time  = "$.time"
    }
    input_template = <<-EOT
      {"source":"glue-jdbc-ingestion","job":<job>,"run_id":<run>,"state":<state>,"time":<time>}
    EOT
  }
}

resource "aws_cloudwatch_event_rule" "crawler_failed" {
  count = local.create_alerts && var.create_crawler ? 1 : 0

  name        = "${var.name}-crawler-failed"
  description = "Glue crawler ${local.crawler_name} failed"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Crawler State Change"]
    detail = {
      crawlerName = [aws_glue_crawler.this[0].name]
      state       = ["Failed"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "crawler_failed" {
  count = local.create_alerts && var.create_crawler ? 1 : 0

  rule = aws_cloudwatch_event_rule.crawler_failed[0].name
  arn  = var.alerts_sns_topic_arn

  input_transformer {
    input_paths = {
      crawler = "$.detail.crawlerName"
      state   = "$.detail.state"
      time    = "$.time"
    }
    input_template = <<-EOT
      {"source":"glue-jdbc-ingestion","crawler":<crawler>,"state":<state>,"time":<time>}
    EOT
  }
}
