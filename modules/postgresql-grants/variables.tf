variable "database" {
  description = "Database the ingestion role reads."
  type        = string
}

variable "role" {
  description = "Existing PostgreSQL role the Glue job logs in as (the secret's username). This module only grants; it never creates roles or passwords."
  type        = string
}

variable "schemas" {
  description = "Schemas to grant USAGE and SELECT on."
  type        = list(string)
  default     = ["public"]
  nullable    = false

  validation {
    condition     = length(var.schemas) > 0
    error_message = "schemas needs at least one schema."
  }
}

variable "tables" {
  description = "Tables to grant SELECT on, as `schema.table`. Empty grants every existing table of `schemas` (what discover mode needs)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for t in var.tables : length(split(".", t)) == 2])
    error_message = "tables must be schema.table."
  }
}

variable "table_owners" {
  description = "Roles that CREATE the tables (usually the one that runs the service's migrations, not the admin user). Each gets default privileges, so tables they create later are readable without another apply. The Terraform user must be a member of each owner (or superuser); default privileges for a role that never creates tables do nothing."
  type        = list(string)
  default     = []
  nullable    = false
}
