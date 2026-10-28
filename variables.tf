################################################################################
# General
################################################################################

variable "name" {
  description = "Base name for the job and its connection, crawler, triggers, role and alert rules. Include the environment (e.g. `orders-db-prd`) so two environments in one account never collide."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,54}$", var.name))
    error_message = "name must be 1-55 characters: letters, digits, '-' or '_' (derived names add suffixes up to 9 characters)."
  }
}

variable "tags" {
  description = "Tags for every taggable resource. Prefer provider `default_tags` for organization-wide tags."
  type        = map(string)
  default     = {}
}

################################################################################
# Script
################################################################################

variable "scripts_bucket" {
  description = "S3 bucket that holds the job script."
  type        = string
}

variable "scripts_prefix" {
  description = "S3 prefix for uploaded scripts. The key is `<scripts_prefix>/<name>/<file>`."
  type        = string
  default     = "scripts/jobs"
}

variable "script_local_path" {
  description = "Local path of a custom script to upload. Leave both this and `script_s3_key` null to use the bundled PostgreSQL extractor (`scripts/pg_extractor.py`)."
  type        = string
  default     = null
}

variable "script_s3_key" {
  description = "S3 key of a script that already exists in `scripts_bucket` (nothing is uploaded). Takes precedence over `script_local_path`."
  type        = string
  default     = null
}

################################################################################
# Source and credentials
################################################################################

variable "jdbc_url" {
  description = "JDBC URL of the source, e.g. `jdbc:postgresql://host:5432/db`. Used by the Glue connection and passed to the job as `--jdbc_url`."
  type        = string

  validation {
    condition     = can(regex("^jdbc:[a-z0-9]+://", var.jdbc_url))
    error_message = "jdbc_url must look like jdbc:<engine>://host:port/database."
  }
}

variable "secret_arn" {
  description = "Secrets Manager secret ARN with the source credentials (`username`/`password`, or `username` alone for RDS IAM auth). The job resolves it at runtime from `--secret_id`; credentials never reach job arguments, connection properties or Terraform state."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+", var.secret_arn))
    error_message = "secret_arn must be a full Secrets Manager secret ARN."
  }
}

variable "secret_kms_key_arn" {
  description = "Customer managed KMS key that encrypts the secret, if any. Grants `kms:Decrypt` to the created role."
  type        = string
  default     = null
}

variable "rds_iam_auth_resource_arns" {
  description = "`rds-db:connect` resources (`arn:aws:rds-db:<region>:<account>:dbuser:<resource-id>/<user>`) for IAM database authentication. Empty when the secret carries a password."
  type        = list(string)
  default     = []
  nullable    = false
}

################################################################################
# Glue connection (network)
################################################################################

variable "create_connection" {
  description = "Create a JDBC Glue connection. It only provides the network wiring (ENIs in your VPC) and references the secret through `SECRET_ID`. Set false for sources reachable without a VPC."
  type        = bool
  default     = true
}

variable "attach_connection_to_job" {
  description = "Attach the connection to the job. Set false to keep the connection but run the job outside the VPC (e.g. Athena runners)."
  type        = bool
  default     = true
}

variable "connection_name" {
  description = "Glue connection name. Defaults to `name`."
  type        = string
  default     = null
}

variable "connection_properties" {
  description = "Extra connection properties merged over `JDBC_CONNECTION_URL` and `SECRET_ID` (e.g. `JDBC_ENFORCE_SSL`). USERNAME and PASSWORD are rejected: they would be stored in plain text in state and returned by `glue:GetConnection`."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = length(setintersection([for k in keys(var.connection_properties) : upper(k)], ["USERNAME", "PASSWORD"])) == 0
    error_message = "Do not pass USERNAME/PASSWORD in connection_properties; use secret_arn."
  }
}

variable "subnet_id" {
  description = "Subnet for the connection ENIs. Required when `create_connection` is true. It needs a route to S3 (gateway endpoint) and to Secrets Manager (interface endpoint or NAT)."
  type        = string
  default     = null

  validation {
    condition     = !var.create_connection || var.subnet_id != null
    error_message = "create_connection = true needs subnet_id."
  }
}

variable "security_group_ids" {
  description = "Security groups for the connection ENIs. Glue requires one of them to allow all TCP from itself (self-referencing rule)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = !var.create_connection || length(var.security_group_ids) > 0
    error_message = "create_connection = true needs at least one security group."
  }
}

variable "availability_zone" {
  description = "Availability zone of `subnet_id`. Looked up from the subnet when null."
  type        = string
  default     = null
}

################################################################################
# Glue job
################################################################################

variable "job_type" {
  description = "`pythonshell` (0.0625 or 1 DPU; right for most table dumps) or `glueetl` (Spark, sized with workers). Changing it replaces the job."
  type        = string
  default     = "pythonshell"

  validation {
    condition     = contains(["pythonshell", "glueetl"], var.job_type)
    error_message = "job_type must be pythonshell or glueetl."
  }
}

variable "glue_version" {
  description = "Glue version. Defaults to `3.0` for pythonshell and `4.0` for glueetl."
  type        = string
  default     = null
}

variable "python_version" {
  description = "Python version. Defaults to `3.9` for pythonshell and `3` for glueetl."
  type        = string
  default     = null
}

variable "max_capacity" {
  description = "DPUs for pythonshell jobs: 0.0625 or 1. Ignored for glueetl."
  type        = number
  default     = 0.0625

  validation {
    condition     = contains([0.0625, 1], var.max_capacity)
    error_message = "max_capacity must be 0.0625 or 1."
  }
}

variable "worker_type" {
  description = "Spark worker type for glueetl jobs. Ignored for pythonshell."
  type        = string
  default     = "G.1X"

  validation {
    condition     = contains(["G.025X", "G.1X", "G.2X", "G.4X", "G.8X", "Z.2X"], var.worker_type)
    error_message = "worker_type must be one of G.025X, G.1X, G.2X, G.4X, G.8X, Z.2X."
  }
}

variable "number_of_workers" {
  description = "Spark worker count for glueetl jobs (minimum 2). Ignored for pythonshell."
  type        = number
  default     = 2

  validation {
    condition     = var.number_of_workers >= 2
    error_message = "number_of_workers must be at least 2."
  }
}

variable "execution_class" {
  description = "`STANDARD` or `FLEX` (cheaper, delayed start). Applies to glueetl only; the API rejects it for pythonshell."
  type        = string
  default     = null

  validation {
    condition     = var.execution_class == null ? true : contains(["STANDARD", "FLEX"], var.execution_class)
    error_message = "execution_class must be STANDARD, FLEX or null."
  }
}

variable "job_timeout" {
  description = "Job timeout in minutes. Keep it explicit: a stuck job ends in TIMEOUT (which the alert rule catches) instead of running for Glue's 48 h default."
  type        = number
  default     = 60

  validation {
    condition     = var.job_timeout >= 1 && var.job_timeout <= 2880
    error_message = "job_timeout must be between 1 and 2880 minutes."
  }
}

variable "max_retries" {
  description = "Automatic retries after a failed run."
  type        = number
  default     = 0
}

variable "max_concurrent_runs" {
  description = "Concurrent runs allowed. Keep 1 when the job overwrites a prefix: two writers on the same prefix duplicate rows. Extra StartJobRun calls fail with ConcurrentRunsExceeded, so callers (Step Functions) should retry."
  type        = number
  default     = 1

  validation {
    condition     = var.max_concurrent_runs >= 1
    error_message = "max_concurrent_runs must be at least 1."
  }
}

variable "pythonshell_library_set" {
  description = "`--library-set` for pythonshell 3.9 jobs. `analytics` preloads pyarrow, pandas and boto3. Null omits it."
  type        = string
  default     = "analytics"
}

variable "extra_py_files" {
  description = "S3 URIs of wheels or .py files for `--extra-py-files`. Use it for pg8000 when the subnet has no internet access (see README)."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "python_modules" {
  description = "pip requirements for `--additional-python-modules` (e.g. `pg8000==1.31.5`). Needs internet access (NAT) from the subnet."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "default_arguments" {
  description = "Extra job arguments, merged last (they override the module's)."
  type        = map(string)
  default     = {}
  nullable    = false
}

################################################################################
# Output and bundled extractor
################################################################################

variable "output_s3_path" {
  description = "S3 prefix the job writes to (`s3://bucket/prefix/`). Passed as `--output_path_base`; scopes the role's write access and is the crawler's default target."
  type        = string

  validation {
    condition     = can(regex("^s3://[a-z0-9.-]+/.+/$", var.output_s3_path))
    error_message = "output_s3_path must be s3://bucket/prefix/ (with a prefix and a trailing slash)."
  }
}

variable "extract_tables" {
  description = "Bundled extractor only: tables to dump, as `schema.table` (schema defaults to public). Ignored when `extract_discover` is true."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "extract_discover" {
  description = "Bundled extractor only: dump every base table of `extract_schema` instead of `extract_tables`. Tables without SELECT are skipped and reported; other failures fail the run after the remaining tables are written."
  type        = bool
  default     = false
}

variable "extract_schema" {
  description = "Bundled extractor only: schema scanned in discover mode."
  type        = string
  default     = "public"
}

variable "extract_exclude_tables" {
  description = "Bundled extractor only: tables to skip in discover mode, in addition to migration bookkeeping tables (`schema_migrations`, `flyway_schema_history`, ...)."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "extract_ssl_mode" {
  description = "Bundled extractor only: `require` (TLS without certificate verification, like libpq sslmode=require) or `verify-full` (needs `--ssl_root_cert` in default_arguments). There is no plaintext fallback."
  type        = string
  default     = "require"

  validation {
    condition     = contains(["require", "verify-full"], var.extract_ssl_mode)
    error_message = "extract_ssl_mode must be require or verify-full."
  }
}

################################################################################
# IAM
################################################################################

variable "create_iam_role" {
  description = "Create a least-privilege role for the job and crawler. Set false and pass `iam_role_arn` to bring your own."
  type        = bool
  default     = true
}

variable "iam_role_arn" {
  description = "Existing role for the job and crawler. Required when `create_iam_role` is false."
  type        = string
  default     = null
}

variable "iam_role_permissions_boundary" {
  description = "Permissions boundary ARN for the created role."
  type        = string
  default     = null
}

variable "iam_additional_read_s3_paths" {
  description = "Extra `s3://bucket/prefix/` paths the role may read (e.g. custom libraries, CA bundles)."
  type        = list(string)
  default     = []
  nullable    = false
}

################################################################################
# Schedule
################################################################################

variable "create_trigger" {
  description = "Create a Glue trigger for the job."
  type        = bool
  default     = false
}

variable "trigger_name" {
  description = "Trigger name. Defaults to `name`."
  type        = string
  default     = null
}

variable "trigger_type" {
  description = "ON_DEMAND or SCHEDULED."
  type        = string
  default     = "SCHEDULED"

  validation {
    condition     = contains(["ON_DEMAND", "SCHEDULED"], var.trigger_type)
    error_message = "trigger_type must be ON_DEMAND or SCHEDULED."
  }
}

variable "trigger_schedule" {
  description = "Cron for SCHEDULED triggers, e.g. `cron(0 3 * * ? *)` (UTC)."
  type        = string
  default     = null
}

variable "trigger_enabled" {
  description = "Whether the trigger is active."
  type        = bool
  default     = true
}

################################################################################
# Crawler
################################################################################

variable "create_crawler" {
  description = "Create a crawler that catalogs the output. Only needed when the schema changes: the job overwrites the data and Athena reads it right away."
  type        = bool
  default     = false
}

variable "crawler_name" {
  description = "Crawler name. Defaults to `name`."
  type        = string
  default     = null
}

variable "crawler_database_name" {
  description = "Glue Catalog database for the crawler (must exist). Required when `create_crawler` is true."
  type        = string
  default     = null

  validation {
    condition     = !var.create_crawler || var.crawler_database_name != null
    error_message = "create_crawler = true needs crawler_database_name."
  }
}

variable "crawler_s3_target_path" {
  description = "Crawler target. Defaults to `output_s3_path`."
  type        = string
  default     = null
}

variable "crawler_exclusions" {
  description = "Glob patterns the crawler skips."
  type        = list(string)
  default     = ["**/_SUCCESS", "**/_temporary/**"]
  nullable    = false
}

variable "crawler_schedule" {
  description = "Own cron for the crawler. Weekly is usually enough (a crawler run bills at least 10 minutes). Ignored when `chain_crawler` is true."
  type        = string
  default     = null
}

variable "chain_crawler" {
  description = "Start the crawler from a conditional trigger when the job SUCCEEDS, instead of a cron. Conditional triggers fire only for runs started by Glue triggers, not for StartJobRun from Step Functions or the CLI."
  type        = bool
  default     = false
}

variable "crawler_on_job_failure" {
  description = "With `chain_crawler`, also start the crawler when the job FAILS (for jobs that write independent tables and fail if any one fails). Glue rejects two conditions on the same job in one predicate, so this is a second trigger."
  type        = bool
  default     = false
}

variable "crawler_table_level" {
  description = "Folder depth where the crawler creates tables (bucket = 1). Set it to the depth of `<prefix>/<table>/` so a prefix with a single table is not collapsed into one table with `partition_0`. Null keeps Glue's grouping."
  type        = number
  default     = null
}

variable "crawler_schema_change_update_behavior" {
  description = "UPDATE_IN_DATABASE (update tables in place) or LOG."
  type        = string
  default     = "UPDATE_IN_DATABASE"

  validation {
    condition     = contains(["UPDATE_IN_DATABASE", "LOG"], var.crawler_schema_change_update_behavior)
    error_message = "Must be UPDATE_IN_DATABASE or LOG."
  }
}

variable "crawler_schema_change_delete_behavior" {
  description = "LOG (default: never drop tables that disappear), DEPRECATE_IN_DATABASE or DELETE_FROM_DATABASE."
  type        = string
  default     = "LOG"

  validation {
    condition     = contains(["LOG", "DEPRECATE_IN_DATABASE", "DELETE_FROM_DATABASE"], var.crawler_schema_change_delete_behavior)
    error_message = "Must be LOG, DEPRECATE_IN_DATABASE or DELETE_FROM_DATABASE."
  }
}

################################################################################
# Alerts
################################################################################

variable "alerts_sns_topic_arn" {
  description = "SNS topic for EventBridge alerts when the job ends in FAILED/TIMEOUT/ERROR or the crawler fails. Its policy must allow `events.amazonaws.com` to publish. Null creates no alerts."
  type        = string
  default     = null
}
