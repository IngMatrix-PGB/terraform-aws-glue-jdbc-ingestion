# ------------------------------------------------------------------------------
# Variables (multi-ambiente vía tfvars). Secret: por nombre o por ARN.
# ------------------------------------------------------------------------------
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Región AWS."
}

variable "environment_suffix" {
  type        = string
  description = "Sufijo de ambiente (dev, pre, prd)."
}

# --- Secrets Manager: uno de los dos debe estar definido ---
variable "jdbc_secret_name" {
  type        = string
  default     = null
  description = "Nombre del secret en Secrets Manager (ej. env/datalake/jdbc-credentials). Requerido si jdbc_secret_arn es null."
}

variable "jdbc_secret_arn" {
  type        = string
  default     = null
  description = "ARN del secret. Si se define, tiene prioridad sobre jdbc_secret_name. El secret debe ser JSON: {\"username\":\"...\", \"password\":\"...\"}."
}

# --- Red (Glue Connection) ---
variable "subnet_id" {
  type        = string
  description = "Subnet ID para la Glue Connection (VPC)."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security Group IDs para la Glue Connection."
}

# --- JDBC: PostgreSQL ---
variable "jdbc_host_postgres" {
  type        = string
  description = "Host del servidor PostgreSQL."
}

variable "jdbc_port_postgres" {
  type        = string
  default     = "5432"
}

variable "jdbc_database_postgres" {
  type        = string
  default     = "appdb"
}

# --- JDBC: MySQL ---
variable "jdbc_host_mysql" {
  type        = string
  description = "Host del servidor MySQL."
}

variable "jdbc_port_mysql" {
  type        = string
  default     = "3306"
}

variable "jdbc_database_mysql" {
  type        = string
  default     = "appdb"
}

# --- S3 ---
variable "scripts_bucket" {
  type        = string
  description = "Bucket S3 para scripts Glue y directorio temporal."
}

# --- Opcionales ---
variable "glue_trigger_type" {
  type        = string
  default     = "ON_DEMAND"
  description = "ON_DEMAND o SCHEDULED."
}

variable "glue_trigger_schedule" {
  type        = string
  default     = "cron(0 3 * * ? *)"
  description = "Cron para trigger SCHEDULED."
}

variable "crawler_exclusions" {
  type        = list(string)
  default     = ["_SUCCESS", "logs/"]
  description = "Exclusiones del crawler."
}
