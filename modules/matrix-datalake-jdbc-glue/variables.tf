variable "name" {
  description = "Base name for resources (job/connection/crawler/trigger). Keep it short."
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources that support it."
  type        = map(string)
  default     = {}
}

# --- Scripts / S3 ---
variable "scripts_bucket" {
  description = "S3 bucket where Glue scripts are stored."
  type        = string
}

variable "scripts_prefix" {
  description = "S3 prefix under scripts_bucket for this job (e.g., scripts/jobs/)."
  type        = string
  default     = "scripts/jobs"
}

variable "script_local_path" {
  description = "Local path to the Glue ETL script (python). If provided, the module uploads it to S3."
  type        = string
  default     = null
}

variable "script_s3_key" {
  description = "Optional: explicit S3 key for the script. If not set, it is derived from scripts_prefix/name/basename(script_local_path)."
  type        = string
  default     = null
}

# --- Glue Connection (JDBC) ---
variable "create_connection" {
  description = "Whether to create an aws_glue_connection."
  type        = bool
  default     = true
}

variable "connection_name" {
  description = "Glue connection name. Defaults to name if null."
  type        = string
  default     = null
}

variable "connection_type" {
  description = "Glue connection type. For JDBC use 'JDBC'."
  type        = string
  default     = "JDBC"
}

variable "connection_properties" {
  description = "Map of connection properties (e.g., JDBC_CONNECTION_URL, USERNAME, PASSWORD)."
  type        = map(string)
  default     = {}
}

variable "subnet_id" {
  description = "Subnet ID for Glue connection network requirements."
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "Security Group IDs for Glue connection network requirements."
  type        = list(string)
  default     = []
}

variable "availability_zone" {
  description = "Availability Zone for Glue connection physical requirements (optional)."
  type        = string
  default     = null
}

# --- Glue Job ---
variable "iam_role_arn" {
  description = "IAM Role ARN for the Glue Job."
  type        = string
}

variable "glue_version" {
  description = "Glue version, e.g., '4.0' or '3.0'."
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Worker type (G.1X, G.2X, G.4X, etc)."
  type        = string
  default     = "G.1X"
}

variable "number_of_workers" {
  description = "Number of workers."
  type        = number
  default     = 2
}

variable "job_timeout" {
  description = "Job timeout in minutes."
  type        = number
  default     = 60
}

variable "max_retries" {
  description = "Max retries."
  type        = number
  default     = 1
}

variable "default_arguments" {
  description = "Glue Job default arguments."
  type        = map(string)
  default     = {}
}

# --- Glue Crawler (optional) ---
variable "create_crawler" {
  description = "Whether to create a Glue Crawler for an S3 target."
  type        = bool
  default     = true
}

variable "crawler_name" {
  description = "Crawler name. Defaults to name if null."
  type        = string
  default     = null
}

variable "crawler_database_name" {
  description = "Glue Catalog database name for the crawler."
  type        = string
  default     = null
}

variable "crawler_s3_target_path" {
  description = "S3 target path for crawler, e.g., s3://bucket/raw/table/."
  type        = string
  default     = null
}

variable "crawler_exclusions" {
  description = "Crawler exclusions."
  type        = list(string)
  default     = []
}

variable "crawler_schedule" {
  description = "Optional cron schedule for crawler (e.g., cron(0 3 * * ? *))."
  type        = string
  default     = null
}

# --- Glue Trigger (optional) ---
variable "create_trigger" {
  description = "Whether to create a Glue trigger for the job."
  type        = bool
  default     = false
}

variable "trigger_name" {
  description = "Trigger name. Defaults to name if null."
  type        = string
  default     = null
}

variable "trigger_type" {
  description = "ON_DEMAND or SCHEDULED."
  type        = string
  default     = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SCHEDULED"], var.trigger_type)
    error_message = "trigger_type must be ON_DEMAND or SCHEDULED"
  }
}

variable "trigger_schedule" {
  description = "Cron expression for SCHEDULED trigger (e.g., cron(0 2 * * ? *))."
  type        = string
  default     = null
}
