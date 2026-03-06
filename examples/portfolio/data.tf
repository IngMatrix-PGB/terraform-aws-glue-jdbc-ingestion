# ------------------------------------------------------------------------------
# Data sources (patrón datalake: identidad, región, subnet, secret)
# El secret se referencia por nombre O por ARN; la versión se usa para user/pass.
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "glue" {
  id = var.subnet_id
}

# Secret por nombre (solo cuando no se pasa jdbc_secret_arn)
data "aws_secretsmanager_secret" "jdbc" {
  count = var.jdbc_secret_arn == null ? 1 : 0
  name  = var.jdbc_secret_name
}

# Credenciales JDBC: usuario y contraseña se leen de aquí y se pasan a connection_properties
data "aws_secretsmanager_secret_version" "jdbc" {
  secret_id = var.jdbc_secret_arn != null ? var.jdbc_secret_arn : data.aws_secretsmanager_secret.jdbc[0].id
}
