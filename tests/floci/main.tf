# Applies the module with every option on to Floci (a local AWS emulator) by
# tests/floci/run.sh. Every dependency (VPC, buckets, secret, KMS key, SNS
# topic, catalog database) is created in the same apply, which is what
# catches count/for_each values unknown at plan time.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "6.60.0" }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = false
  skip_metadata_api_check     = true
  s3_use_path_style           = true
  endpoints {
    s3             = var.endpoint
    s3control      = var.endpoint
    glue           = var.endpoint
    iam            = var.endpoint
    sts            = var.endpoint
    kms            = var.endpoint
    secretsmanager = var.endpoint
    ec2            = var.endpoint
    events         = var.endpoint
    sns            = var.endpoint
    logs           = var.endpoint
    rds            = var.endpoint
  }
}

resource "aws_vpc" "this" { cidr_block = "10.42.0.0/16" }
resource "aws_subnet" "this" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = "us-east-1a"
}
resource "aws_security_group" "glue" {
  vpc_id = aws_vpc.this.id
  name   = "glue-e2e"
}

resource "aws_s3_bucket" "scripts" { bucket = "e2e-glue-scripts" }
resource "aws_s3_bucket" "lake" { bucket = "e2e-datalake" }

resource "aws_kms_key" "lake" { description = "e2e" }

resource "aws_secretsmanager_secret" "reader" {
  name                    = "e2e/reader"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "reader" {
  secret_id     = aws_secretsmanager_secret.reader.id
  secret_string = jsonencode({ username = "lake_reader", password = "e2e-only" })
}

resource "aws_sns_topic" "alerts" { name = "e2e-alerts" }
resource "aws_glue_catalog_database" "raw" { name = "raw_e2e" }

module "orders" {
  source = "../.."

  name           = "orders-e2e"
  scripts_bucket = aws_s3_bucket.scripts.bucket
  output_s3_path = "s3://${aws_s3_bucket.lake.bucket}/raw/orders/"

  jdbc_url   = "jdbc:postgresql://orders.example.internal:5432/orders"
  secret_arn = aws_secretsmanager_secret.reader.arn

  subnet_id          = aws_subnet.this.id
  security_group_ids = [aws_security_group.glue.id]

  extract_tables               = ["public.orders", "public.payments"]
  extract_incremental          = { "public.payments" = "created_at" }
  extract_statement_timeout_ms = 60000
  python_modules               = ["pg8000==1.31.5"]

  kms_key_arn                   = aws_kms_key.lake.arn
  secret_kms_key_arn            = aws_kms_key.lake.arn
  create_security_configuration = true

  create_trigger   = true
  trigger_schedule = "cron(0 9 * * ? *)"

  create_crawler        = true
  chain_crawler         = true
  crawler_database_name = aws_glue_catalog_database.raw.name
  crawler_table_level   = 3

  create_alerts        = true
  alerts_sns_topic_arn = aws_sns_topic.alerts.arn
}
