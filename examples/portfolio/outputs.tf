output "glue_role_arn" {
  value       = aws_iam_role.glue_jdbc.arn
  description = "IAM role usado por los Glue jobs."
}

output "job_postgres_name" {
  value       = module.jdbc_postgres.job_name
  description = "Nombre del Glue job PostgreSQL."
}

output "job_mysql_name" {
  value       = module.jdbc_mysql.job_name
  description = "Nombre del Glue job MySQL."
}

output "connection_postgres" {
  value       = module.jdbc_postgres.connection_name
  description = "Glue Connection PostgreSQL."
}

output "connection_mysql" {
  value       = module.jdbc_mysql.connection_name
  description = "Glue Connection MySQL."
}
