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
  description = "Bucket for the job script."
  type        = string
}

variable "lake_bucket" {
  description = "Bucket the Parquet files are written to."
  type        = string
}

variable "db_host" {
  description = "PostgreSQL host."
  type        = string
}

variable "secret_arn" {
  description = "Secret with {\"username\": \"...\", \"password\": \"...\"}."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet with routes to the database, S3 and Secrets Manager."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups for the Glue ENIs (one must allow all TCP from itself)."
  type        = list(string)
}
