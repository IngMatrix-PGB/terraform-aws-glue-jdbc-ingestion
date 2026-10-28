# One PostgreSQL database dumped every 30 minutes to Parquet with the bundled
# extractor. Credentials come from an existing secret; nothing sensitive is
# written to state.
module "orders_db" {
  source = "../.."

  name           = "orders-db-${var.environment}"
  scripts_bucket = var.scripts_bucket
  output_s3_path = "s3://${var.lake_bucket}/raw/orders-db/"

  jdbc_url   = "jdbc:postgresql://${var.db_host}:5432/orders"
  secret_arn = var.secret_arn

  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids

  extract_discover = true
  # pg8000 from PyPI; needs a NAT. Without internet access use extra_py_files.
  python_modules = ["pg8000==1.31.5"]

  create_trigger   = true
  trigger_schedule = "cron(0 9 * * ? *)" # daily
}
