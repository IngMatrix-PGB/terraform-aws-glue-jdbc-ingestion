# ------------------------------------------------------------------------------
# Portfolio example: estilo datalake, escalable, con Secrets Manager
# Root module: se ejecuta desde esta carpeta con -var-file=workload-demo/terraform.tfvars
# ------------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# IAM: rol mínimo para Glue (S3, Glue Catalog, EC2/VPC, Secrets Manager)
# Un solo rol reutilizado por todos los jobs del ejemplo (escalable: más jobs, mismo rol)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "glue_jdbc" {
  name               = "matrix-portfolio-glue-jdbc-${var.environment_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "glue_jdbc" {
  name   = "glue-jdbc-inline"
  role   = aws_iam_role.glue_jdbc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ScriptsAndTemp"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.scripts_bucket}",
          "arn:aws:s3:::${var.scripts_bucket}/*"
        ]
      },
      {
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetTable", "glue:CreateTable", "glue:UpdateTable",
          "glue:GetDatabase", "glue:CreateDatabase", "glue:GetConnection"
        ]
        Resource = ["*"]
      },
      {
        Sid    = "EC2VPC"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeSecurityGroups",
          "ec2:DescribeNetworkInterfaces", "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Permiso para leer el secret (Glue necesita GetSecretValue en runtime si el job usa el connection)
resource "aws_iam_role_policy" "glue_secrets" {
  name   = "glue-secrets-read"
  role   = aws_iam_role.glue_jdbc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [local.jdbc_secret_arn]
    }]
  })
}

# ------------------------------------------------------------------------------
# Glue Job 1: PostgreSQL (conexión y credenciales desde locals / Secrets Manager)
# ------------------------------------------------------------------------------
module "jdbc_postgres" {
  source = "../../modules/matrix-datalake-jdbc-glue"

  name            = "portfolio-postgres-${var.environment_suffix}"
  scripts_bucket   = local.scripts_bucket
  scripts_prefix  = "scripts/portfolio"
  script_local_path = "${path.module}/scripts/etl_postgres.py"

  create_connection   = true
  connection_type     = "JDBC"
  connection_properties = local.connection_props_postgres

  subnet_id          = var.subnet_id
  security_group_ids  = var.security_group_ids
  availability_zone  = data.aws_subnet.glue.availability_zone

  iam_role_arn      = aws_iam_role.glue_jdbc.arn
  glue_version     = "4.0"
  worker_type      = "G.1X"
  number_of_workers = 2

  create_crawler         = true
  crawler_database_name  = "portfolio_postgres_${var.environment_suffix}"
  crawler_s3_target_path  = "s3://${var.scripts_bucket}/raw/postgres/"
  crawler_exclusions      = var.crawler_exclusions

  create_trigger   = true
  trigger_name     = "trigger-portfolio-postgres"
  trigger_type     = var.glue_trigger_type
  trigger_schedule = var.glue_trigger_schedule

  default_arguments = {
    "--TempDir"           = local.temp_dir
    "--extra-jars"        = ""
    "--example.dbtable"   = "public.sample_table"
  }

  tags = {
    project     = "matrix-datalake"
    portfolio   = "true"
    environment = var.environment_suffix
  }
}

# ------------------------------------------------------------------------------
# Glue Job 2: MySQL (muestra escalabilidad: otro job, misma estructura)
# ------------------------------------------------------------------------------
module "jdbc_mysql" {
  source = "../../modules/matrix-datalake-jdbc-glue"

  name            = "portfolio-mysql-${var.environment_suffix}"
  scripts_bucket   = local.scripts_bucket
  scripts_prefix  = "scripts/portfolio"
  script_local_path = "${path.module}/scripts/etl_mysql.py"

  create_connection   = true
  connection_type     = "JDBC"
  connection_properties = local.connection_props_mysql

  subnet_id          = var.subnet_id
  security_group_ids  = var.security_group_ids
  availability_zone  = data.aws_subnet.glue.availability_zone

  iam_role_arn      = aws_iam_role.glue_jdbc.arn
  glue_version     = "4.0"
  worker_type      = "G.1X"
  number_of_workers = 2

  create_crawler         = true
  crawler_database_name  = "portfolio_mysql_${var.environment_suffix}"
  crawler_s3_target_path  = "s3://${var.scripts_bucket}/raw/mysql/"
  crawler_exclusions      = var.crawler_exclusions

  create_trigger   = true
  trigger_name     = "trigger-portfolio-mysql"
  trigger_type     = var.glue_trigger_type
  trigger_schedule = var.glue_trigger_schedule

  default_arguments = {
    "--TempDir"           = local.temp_dir
    "--extra-jars"        = ""
    "--example.dbtable"   = "sample_table"
  }

  tags = {
    project     = "matrix-datalake"
    portfolio   = "true"
    environment = var.environment_suffix
  }
}
