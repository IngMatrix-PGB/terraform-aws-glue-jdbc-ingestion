output "postgres_jobs" {
  description = "Glue job per PostgreSQL source."
  value       = { for k, m in module.postgres : k => m.job_name }
}

output "postgres_crawlers" {
  description = "Crawler per PostgreSQL source."
  value       = { for k, m in module.postgres : k => m.crawler_name }
}

output "mysql_job" {
  description = "Glue job for the MySQL source."
  value       = try(module.mysql[0].job_name, null)
}

output "alerts_topic_arn" {
  description = "SNS topic that receives job and crawler failures."
  value       = aws_sns_topic.alerts.arn
}
