# Several PostgreSQL sources from one map (for_each, not copy-pasted module
# blocks), a chained crawler per source, failure alerts to SNS, and one Spark
# job with a custom script for a MySQL source.

locals {
  # Wheels in ./libs (see README) are uploaded and used through
  # --extra-py-files, so the subnet needs no internet access. Without them the
  # jobs install pg8000 from PyPI (needs a NAT).
  wheels = fileset("${path.module}/libs", "*.whl")
}

resource "aws_s3_object" "wheels" {
  for_each = local.wheels

  bucket = var.scripts_bucket
  key    = "libs/${each.value}"
  source = "${path.module}/libs/${each.value}"
  etag   = filemd5("${path.module}/libs/${each.value}")
}

################################################################################
# Alerts
################################################################################

resource "aws_sns_topic" "alerts" {
  name = "glue-ingestion-alerts-${var.environment}"
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alerts_email != null ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

data "aws_caller_identity" "current" {}

################################################################################
# PostgreSQL sources (bundled extractor)
################################################################################

resource "aws_glue_catalog_database" "raw" {
  for_each = var.postgres_sources

  name = replace("raw_${each.key}_${var.environment}", "-", "_")
}

module "postgres" {
  source   = "../.."
  for_each = var.postgres_sources

  name           = "${each.key}-${var.environment}"
  scripts_bucket = var.scripts_bucket
  output_s3_path = "s3://${var.lake_bucket}/raw/${each.key}/"

  jdbc_url   = "jdbc:postgresql://${each.value.host}:${each.value.port}/${each.value.database}"
  secret_arn = each.value.secret_arn

  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids

  extract_discover       = length(each.value.tables) == 0
  extract_tables         = each.value.tables
  extract_exclude_tables = each.value.exclude_tables

  extra_py_files = [for o in aws_s3_object.wheels : "s3://${o.bucket}/${o.key}"]
  python_modules = length(local.wheels) == 0 ? ["pg8000==1.31.5"] : []

  create_trigger   = true
  trigger_schedule = each.value.schedule

  # The crawler runs when a triggered run succeeds. s3://lake/raw/<source>/<table>/
  # puts tables at level 4 (bucket = 1).
  create_crawler        = true
  chain_crawler         = true
  crawler_database_name = aws_glue_catalog_database.raw[each.key].name
  crawler_table_level   = 4

  alerts_sns_topic_arn = aws_sns_topic.alerts.arn
}

################################################################################
# MySQL source (Spark, custom script)
################################################################################

module "mysql" {
  source = "../.."
  count  = var.mysql_source != null ? 1 : 0

  name              = "legacy-mysql-${var.environment}"
  scripts_bucket    = var.scripts_bucket
  script_local_path = "${path.module}/scripts/mysql_to_parquet.py"
  output_s3_path    = "s3://${var.lake_bucket}/raw/legacy-mysql/"

  jdbc_url   = "jdbc:mysql://${var.mysql_source.host}:3306/${var.mysql_source.database}"
  secret_arn = var.mysql_source.secret_arn

  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids

  job_type          = "glueetl"
  worker_type       = "G.1X"
  number_of_workers = 2
  execution_class   = "FLEX"
  job_timeout       = 120

  default_arguments = {
    "--connection_name" = "legacy-mysql-${var.environment}"
    "--tables"          = jsonencode(var.mysql_source.tables)
  }

  create_trigger   = true
  trigger_schedule = "cron(15 3 * * ? *)"

  alerts_sns_topic_arn = aws_sns_topic.alerts.arn
}
