output "job_name" {
  description = "Glue job name."
  value       = module.orders_db.job_name
}

output "role_arn" {
  description = "Role created for the job."
  value       = module.orders_db.role_arn
}
