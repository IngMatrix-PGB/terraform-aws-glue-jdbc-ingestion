output "schemas" {
  description = "Schemas the role can read."
  value       = var.schemas
}

output "default_privilege_owners" {
  description = "Roles whose future tables the role can read."
  value       = var.table_owners
}
