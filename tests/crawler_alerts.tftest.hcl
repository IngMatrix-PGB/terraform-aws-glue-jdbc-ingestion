mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "us-east-1a" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                  = "orders-db-test"
  scripts_bucket        = "scripts-bucket"
  output_s3_path        = "s3://lake-bucket/raw/orders-db/"
  jdbc_url              = "jdbc:postgresql://db.example.com:5432/orders"
  secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:orders/reader-AbCdEf"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_ids    = ["sg-0123456789abcdef0"]
  extract_tables        = ["public.orders"]
  create_trigger        = true
  trigger_schedule      = "cron(0/30 * * * ? *)"
  create_crawler        = true
  crawler_database_name = "raw_orders"
  alerts_sns_topic_arn  = "arn:aws:sns:us-east-1:123456789012:alerts"
}

run "scheduled_crawler" {
  command = plan

  variables {
    crawler_schedule = "cron(0 3 ? * MON *)"
  }

  assert {
    condition     = aws_glue_crawler.this[0].schedule == "cron(0 3 ? * MON *)" && length(aws_glue_trigger.crawler_on_job_success) == 0
    error_message = "Unchained crawler keeps its own cron."
  }
  assert {
    condition     = aws_glue_crawler.this[0].s3_target[0].path == var.output_s3_path
    error_message = "Crawler targets the output prefix by default."
  }
  assert {
    condition     = aws_glue_crawler.this[0].schema_change_policy[0].delete_behavior == "LOG"
    error_message = "Never drop tables by default."
  }
  assert {
    condition     = jsondecode(aws_glue_crawler.this[0].configuration).CrawlerOutput.Tables.AddOrUpdateBehavior == "MergeNewColumns"
    error_message = "Crawler must merge new columns."
  }
  assert {
    condition     = length(aws_cloudwatch_event_rule.job_failed) == 1 && length(aws_cloudwatch_event_rule.crawler_failed) == 1
    error_message = "Alerts for job and crawler."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.job_failed[0].event_pattern).detail.state == ["FAILED", "TIMEOUT", "ERROR"]
    error_message = "Job alert covers FAILED, TIMEOUT and ERROR."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.job_failed[0].event_pattern).detail.jobName == ["orders-db-test"]
    error_message = "Job alert is scoped to this job."
  }
}

run "chained_crawler" {
  command = plan

  variables {
    chain_crawler          = true
    crawler_on_job_failure = true
    crawler_schedule       = "cron(0 3 ? * MON *)"
    crawler_table_level    = 4
  }

  assert {
    condition     = aws_glue_crawler.this[0].schedule == null
    error_message = "A chained crawler has no cron."
  }
  assert {
    condition     = aws_glue_trigger.crawler_on_job_success[0].predicate[0].conditions[0].state == "SUCCEEDED"
    error_message = "Success trigger must fire on SUCCEEDED."
  }
  assert {
    condition     = aws_glue_trigger.crawler_on_job_failure[0].predicate[0].conditions[0].state == "FAILED"
    error_message = "Failure trigger must fire on FAILED."
  }
  assert {
    condition     = jsondecode(aws_glue_crawler.this[0].configuration).Grouping.TableLevelConfiguration == 4
    error_message = "Table level must reach the configuration."
  }
}

run "delete_permissions_only_when_needed" {
  command = plan

  variables {
    crawler_schema_change_delete_behavior = "DELETE_FROM_DATABASE"
  }

  assert {
    condition = contains(flatten([
      for s in data.aws_iam_policy_document.this[0].statement : s.actions if s.sid == "CrawlerCatalog"
    ]), "glue:DeleteTable")
    error_message = "DELETE_FROM_DATABASE needs glue:DeleteTable."
  }
}

run "no_delete_permissions_by_default" {
  command = plan

  assert {
    condition = !contains(flatten([
      for s in data.aws_iam_policy_document.this[0].statement : s.actions if s.sid == "CrawlerCatalog"
    ]), "glue:DeleteTable")
    error_message = "LOG must not grant glue:DeleteTable."
  }
}
