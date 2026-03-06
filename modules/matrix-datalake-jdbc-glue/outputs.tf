output "job_name" {
  value       = aws_glue_job.this.name
  description = "Glue Job name."
}

output "connection_name" {
  value       = var.create_connection ? aws_glue_connection.this[0].name : null
  description = "Glue Connection name (if created)."
}

output "crawler_name" {
  value       = var.create_crawler ? aws_glue_crawler.this[0].name : null
  description = "Glue Crawler name (if created)."
}

output "trigger_name" {
  value       = var.create_trigger ? aws_glue_trigger.this[0].name : null
  description = "Glue Trigger name (if created)."
}

output "script_s3_uri" {
  value       = var.script_local_path != null ? "s3://${var.scripts_bucket}/${local.script_key}" : null
  description = "S3 URI of the uploaded script (if uploaded)."
}
