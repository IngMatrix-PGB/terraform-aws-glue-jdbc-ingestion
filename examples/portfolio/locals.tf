# ------------------------------------------------------------------------------
# Locals: usuario y contraseña desde Secrets Manager → connection_properties
# Patrón datalake: jsondecode(secret_string) y reutilizar en tantos connection_props_* como fuentes JDBC.
# Escalable: añadir connection_props_sqlserver, etc.
# ------------------------------------------------------------------------------
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.id

  # Decodificar secret (formato JSON: {"username":"...", "password":"..."})
  jdbc_credentials = jsondecode(data.aws_secretsmanager_secret_version.jdbc.secret_string)

  # Connection properties por fuente JDBC (USERNAME y PASSWORD desde el secret)
  connection_props_postgres = {
    JDBC_CONNECTION_URL = "jdbc:postgresql://${var.jdbc_host_postgres}:${var.jdbc_port_postgres}/${var.jdbc_database_postgres}"
    USERNAME            = local.jdbc_credentials.username
    PASSWORD            = local.jdbc_credentials.password
  }

  connection_props_mysql = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${var.jdbc_host_mysql}:${var.jdbc_port_mysql}/${var.jdbc_database_mysql}"
    USERNAME            = local.jdbc_credentials.username
    PASSWORD            = local.jdbc_credentials.password
  }

  # ARN del secret (para política IAM del rol Glue)
  jdbc_secret_arn = coalesce(var.jdbc_secret_arn, try(data.aws_secretsmanager_secret.jdbc[0].arn, null))

  scripts_bucket = var.scripts_bucket
  temp_dir      = "s3://${var.scripts_bucket}/temp/"
}
