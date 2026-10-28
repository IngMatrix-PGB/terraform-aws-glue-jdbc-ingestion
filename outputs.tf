output "job_name" {
  description = "Glue job name."
  value       = aws_glue_job.this.name
}

output "job_arn" {
  description = "Glue job ARN."
  value       = aws_glue_job.this.arn
}

output "script_s3_uri" {
  description = "S3 URI of the job script."
  value       = local.script_location
}

output "role_arn" {
  description = "Role used by the job and the crawler."
  value       = local.role_arn
}

output "role_name" {
  description = "Name of the created role (null when `create_iam_role` is false)."
  value       = try(aws_iam_role.this[0].name, null)
}

output "connection_name" {
  description = "Glue connection name (null when not created)."
  value       = try(aws_glue_connection.this[0].name, null)
}

output "crawler_name" {
  description = "Crawler name (null when not created)."
  value       = try(aws_glue_crawler.this[0].name, null)
}

output "trigger_name" {
  description = "Schedule trigger name (null when not created)."
  value       = try(aws_glue_trigger.this[0].name, null)
}

output "output_s3_path" {
  description = "S3 prefix the job writes to."
  value       = var.output_s3_path
}

output "security_configuration_name" {
  description = "Glue security configuration attached to the job and the crawler, if any."
  value       = local.security_configuration
}

output "state_s3_path" {
  description = "Where the bundled extractor stores incremental watermarks (null without `extract_incremental`)."
  value       = local.incremental ? local.state_s3_path : null
}
