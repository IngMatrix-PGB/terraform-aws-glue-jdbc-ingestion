variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment suffix (dev, stg, prd)."
  type        = string
}

variable "scripts_bucket" {
  description = "Bucket for job scripts and wheels."
  type        = string
}

variable "lake_bucket" {
  description = "Bucket the Parquet files are written to."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet with routes to the databases, S3 and Secrets Manager."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups for the Glue ENIs (one must allow all TCP from itself)."
  type        = list(string)
}

variable "postgres_sources" {
  description = "PostgreSQL databases to ingest. Empty `tables` means discover every table of public."
  type = map(object({
    host           = string
    port           = optional(number, 5432)
    database       = string
    secret_arn     = string
    tables         = optional(list(string), [])
    exclude_tables = optional(list(string), [])
    schedule       = optional(string, "cron(0/30 * * * ? *)")
    # { "schema.table" = "watermark_column" }: appended instead of overwritten.
    incremental = optional(map(string), {})
  }))
}

variable "mysql_source" {
  description = "Optional MySQL source read with Spark through the Glue connection."
  type = object({
    host       = string
    database   = string
    secret_arn = string
    tables     = list(string)
  })
  default = null
}

variable "alerts_email" {
  description = "Email subscribed to the alerts topic (confirm the subscription by email)."
  type        = string
  default     = null
}
