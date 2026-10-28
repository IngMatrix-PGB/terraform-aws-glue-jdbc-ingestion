data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  is_pythonshell = var.job_type == "pythonshell"
  glue_version   = coalesce(var.glue_version, local.is_pythonshell ? "3.0" : "4.0")
  python_version = coalesce(var.python_version, local.is_pythonshell ? "3.9" : "3")

  # Script: an existing S3 key, a custom local file, or the bundled extractor.
  use_bundled_extractor = var.script_s3_key == null && var.script_local_path == null
  upload_script         = var.script_s3_key == null
  script_source         = local.use_bundled_extractor ? "${path.module}/scripts/pg_extractor.py" : var.script_local_path
  script_key = (
    var.script_s3_key != null
    ? var.script_s3_key
    : "${trim(var.scripts_prefix, "/")}/${var.name}/${basename(local.script_source)}"
  )
  script_location = "s3://${var.scripts_bucket}/${local.script_key}"

  connection_name = coalesce(var.connection_name, var.name)
  crawler_name    = coalesce(var.crawler_name, var.name)
  trigger_name    = coalesce(var.trigger_name, var.name)
  role_arn        = var.create_iam_role ? aws_iam_role.this[0].arn : var.iam_role_arn

  security_configuration = var.create_security_configuration ? aws_glue_security_configuration.this[0].name : var.security_configuration

  incremental = local.use_bundled_extractor && length(var.extract_incremental) > 0
  state_s3_path = coalesce(
    var.extract_state_s3_path,
    "s3://${var.scripts_bucket}/${trim(var.scripts_prefix, "/")}/${var.name}/state/",
  )

  output_bucket = regex("^s3://([^/]+)/(.*)$", var.output_s3_path)[0]
  output_prefix = regex("^s3://([^/]+)/(.*)$", var.output_s3_path)[1]

  # Credentials travel only as a secret reference (--secret_id); the job
  # resolves them at runtime. Anything in job arguments is readable with
  # glue:GetJob, so never put a password here.
  common_arguments = {
    "--jdbc_url"         = var.jdbc_url
    "--secret_id"        = var.secret_arn
    "--output_path_base" = var.output_s3_path
  }

  type_arguments = local.is_pythonshell ? (
    var.pythonshell_library_set != null ? { "--library-set" = var.pythonshell_library_set } : {}
    ) : {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-job-insights"              = "true"
  }

  library_arguments = merge(
    length(var.extra_py_files) > 0 ? { "--extra-py-files" = join(",", var.extra_py_files) } : {},
    length(var.python_modules) > 0 ? { "--additional-python-modules" = join(",", var.python_modules) } : {},
  )

  extractor_arguments = local.use_bundled_extractor ? merge(
    {
      "--ssl_mode" = var.extract_ssl_mode
    },
    var.kms_key_arn != null ? { "--s3_kms_key_arn" = var.kms_key_arn } : {},
    local.incremental ? {
      "--incremental" = jsonencode(var.extract_incremental)
      "--state_path"  = local.state_s3_path
    } : {},
    var.extract_discover ? {
      "--discover"       = "true"
      "--schema"         = var.extract_schema
      "--exclude_tables" = jsonencode(var.extract_exclude_tables)
      } : {
      "--tables" = jsonencode(var.extract_tables)
    },
  ) : {}

  default_arguments = merge(
    local.common_arguments,
    local.type_arguments,
    local.library_arguments,
    local.extractor_arguments,
    var.default_arguments,
  )
}

################################################################################
# Script
################################################################################

resource "aws_s3_object" "script" {
  count = local.upload_script ? 1 : 0

  bucket = var.scripts_bucket
  key    = local.script_key
  source = local.script_source
  # etag makes Terraform re-upload when the local file changes.
  etag = filemd5(local.script_source)

  tags = var.tags
}

################################################################################
# Glue connection: network wiring only, credentials by secret reference
################################################################################

data "aws_subnet" "this" {
  count = var.create_connection && var.availability_zone == null && var.subnet_id != null ? 1 : 0

  id = var.subnet_id
}

resource "aws_glue_connection" "this" {
  count = var.create_connection ? 1 : 0

  name            = local.connection_name
  connection_type = "JDBC"

  connection_properties = merge(
    {
      JDBC_CONNECTION_URL = var.jdbc_url
      SECRET_ID           = var.secret_arn
    },
    var.connection_properties,
  )

  physical_connection_requirements {
    subnet_id              = var.subnet_id
    security_group_id_list = var.security_group_ids
    availability_zone      = var.availability_zone != null ? var.availability_zone : try(data.aws_subnet.this[0].availability_zone, null)
  }

  tags = var.tags
}

################################################################################
# Encryption at rest
################################################################################

# Immutable: changing the key replaces it under the same name. The job and
# crawler reference it by name, so they keep pointing at the new one.
resource "aws_glue_security_configuration" "this" {
  count = var.create_security_configuration ? 1 : 0

  name = var.name

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}

################################################################################
# Glue job
################################################################################

# Changing the command type (glueetl <-> pythonshell) cannot be an update:
# UpdateJob replaces the whole definition and the provider keeps the computed
# worker_type/number_of_workers of the Spark job, so the API answers "Worker
# Type is not supported for Job Command pythonshell". This keeper forces a
# replacement only when the command type changes.
resource "terraform_data" "job_command" {
  triggers_replace = var.job_type
}

resource "aws_glue_job" "this" {
  name         = var.name
  description  = "JDBC ingestion: ${var.jdbc_url} -> ${var.output_s3_path}"
  role_arn     = local.role_arn
  glue_version = local.glue_version
  timeout      = var.job_timeout
  max_retries  = var.max_retries

  security_configuration = local.security_configuration

  connections = var.create_connection && var.attach_connection_to_job ? [aws_glue_connection.this[0].name] : []

  command {
    name            = var.job_type
    script_location = local.script_location
    python_version  = local.python_version
  }

  # Python shell is sized with max_capacity; Spark with workers. The API
  # rejects mixing them, and execution_class is Spark-only.
  max_capacity      = local.is_pythonshell ? var.max_capacity : null
  worker_type       = local.is_pythonshell ? null : var.worker_type
  number_of_workers = local.is_pythonshell ? null : var.number_of_workers
  execution_class   = local.is_pythonshell ? null : var.execution_class

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  default_arguments = local.default_arguments

  tags = var.tags

  lifecycle {
    replace_triggered_by = [terraform_data.job_command]

    precondition {
      condition     = var.create_iam_role || var.iam_role_arn != null
      error_message = "Set iam_role_arn when create_iam_role = false."
    }
    precondition {
      condition     = !local.use_bundled_extractor || var.extract_discover || length(var.extract_tables) > 0
      error_message = "The bundled extractor needs extract_tables or extract_discover = true."
    }
    precondition {
      condition     = !local.use_bundled_extractor || local.is_pythonshell
      error_message = "The bundled extractor runs as pythonshell; set job_type = \"pythonshell\" or bring your own script."
    }
    precondition {
      condition     = var.execution_class == null || !local.is_pythonshell
      error_message = "execution_class applies to glueetl jobs only."
    }
    precondition {
      condition     = !var.create_trigger || var.trigger_type != "SCHEDULED" || var.trigger_schedule != null
      error_message = "trigger_type = SCHEDULED needs trigger_schedule."
    }
    precondition {
      condition     = !var.chain_crawler || var.create_crawler
      error_message = "chain_crawler needs create_crawler = true."
    }
    precondition {
      condition     = !var.create_security_configuration || var.kms_key_arn != null
      error_message = "create_security_configuration needs kms_key_arn."
    }
    precondition {
      condition     = !(var.create_security_configuration && var.security_configuration != null)
      error_message = "Set create_security_configuration or security_configuration, not both."
    }
    precondition {
      condition     = length(var.extract_incremental) == 0 || local.use_bundled_extractor
      error_message = "extract_incremental applies to the bundled extractor only."
    }
  }
}

################################################################################
# Schedule
################################################################################

resource "aws_glue_trigger" "this" {
  count = var.create_trigger ? 1 : 0

  name     = local.trigger_name
  type     = var.trigger_type
  schedule = var.trigger_type == "SCHEDULED" ? var.trigger_schedule : null
  enabled  = var.trigger_enabled

  # ON_DEMAND triggers cannot start activated.
  start_on_creation = var.trigger_type == "SCHEDULED" ? var.trigger_enabled : null

  actions {
    job_name = aws_glue_job.this.name
  }

  tags = var.tags
}
