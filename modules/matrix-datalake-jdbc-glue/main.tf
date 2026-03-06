locals {
  connection_name = coalesce(var.connection_name, var.name)
  crawler_name    = coalesce(var.crawler_name, var.name)
  trigger_name    = coalesce(var.trigger_name, var.name)

  script_key = coalesce(
    var.script_s3_key,
    var.script_local_path != null ? "${trim(var.scripts_prefix, "/")}/${var.name}/${basename(var.script_local_path)}" : null
  )
}

# Upload the ETL script (optional)
resource "aws_s3_object" "script" {
  count  = var.script_local_path != null ? 1 : 0
  bucket = var.scripts_bucket
  key    = local.script_key
  source = var.script_local_path

  # Helps Terraform detect local changes
  etag = filemd5(var.script_local_path)
}

# Glue Connection (optional)
resource "aws_glue_connection" "this" {
  count = var.create_connection ? 1 : 0

  name            = local.connection_name
  connection_type = var.connection_type

  connection_properties = var.connection_properties

  dynamic "physical_connection_requirements" {
    for_each = (var.subnet_id != null && length(var.security_group_ids) > 0) ? [1] : []
    content {
      subnet_id              = var.subnet_id
      security_group_id_list = var.security_group_ids
      availability_zone      = var.availability_zone
    }
  }

  tags = var.tags
}

# Glue Job
resource "aws_glue_job" "this" {
  name     = var.name
  role_arn = var.iam_role_arn

  glue_version       = var.glue_version
  worker_type        = var.worker_type
  number_of_workers  = var.number_of_workers
  timeout            = var.job_timeout
  max_retries        = var.max_retries

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = var.script_local_path != null ? "s3://${var.scripts_bucket}/${local.script_key}" : null
  }

  default_arguments = merge({
    "--job-language"            = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"          = "true"
  }, var.default_arguments)

  # Attach the connection name to the job if created
  connections = var.create_connection ? [aws_glue_connection.this[0].name] : []

  tags = var.tags
}

# Glue Crawler (optional)
resource "aws_glue_crawler" "this" {
  count = var.create_crawler ? 1 : 0

  name          = local.crawler_name
  role          = var.iam_role_arn
  database_name = var.crawler_database_name

  dynamic "s3_target" {
    for_each = var.crawler_s3_target_path != null ? [1] : []
    content {
      path       = var.crawler_s3_target_path
      exclusions = var.crawler_exclusions
    }
  }

  schedule = var.crawler_schedule

  tags = var.tags
}

# Glue Trigger (optional)
resource "aws_glue_trigger" "this" {
  count = var.create_trigger ? 1 : 0

  name = local.trigger_name
  type = var.trigger_type

  schedule = var.trigger_type == "SCHEDULED" ? var.trigger_schedule : null

  actions {
    job_name = aws_glue_job.this.name
  }

  tags = var.tags
}
