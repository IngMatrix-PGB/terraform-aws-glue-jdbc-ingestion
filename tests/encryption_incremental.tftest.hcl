# Plan-only tests for encryption at rest and incremental extraction.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "us-east-1a" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name               = "orders-db-test"
  scripts_bucket     = "scripts-bucket"
  output_s3_path     = "s3://lake-bucket/raw/orders-db/"
  jdbc_url           = "jdbc:postgresql://db.example.com:5432/orders"
  secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:orders/reader-AbCdEf"
  subnet_id          = "subnet-0123456789abcdef0"
  security_group_ids = ["sg-0123456789abcdef0"]
  extract_tables     = ["public.orders", "billing.invoices"]
}

run "no_encryption_or_incremental_by_default" {
  command = plan

  assert {
    condition     = length(aws_glue_security_configuration.this) == 0 && aws_glue_job.this.security_configuration == null
    error_message = "Security configuration must be opt-in."
  }
  assert {
    condition     = length([for k in keys(aws_glue_job.this.default_arguments) : k if contains(["--incremental", "--state_path", "--s3_kms_key_arn"], k)]) == 0
    error_message = "No incremental or KMS arguments by default."
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.this[0].statement : s.sid if contains(["UseDataKey", "ReadWriteWatermarks"], s.sid)]) == 0
    error_message = "No KMS or watermark permissions by default."
  }
  assert {
    condition     = output.state_s3_path == null
    error_message = "No state path without incremental tables."
  }
}

run "created_security_configuration" {
  command = plan

  variables {
    kms_key_arn                   = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    create_security_configuration = true
    create_crawler                = true
    crawler_database_name         = "raw_orders"
  }

  assert {
    condition = alltrue([
      aws_glue_security_configuration.this[0].encryption_configuration[0].s3_encryption[0].s3_encryption_mode == "SSE-KMS",
      aws_glue_security_configuration.this[0].encryption_configuration[0].cloudwatch_encryption[0].cloudwatch_encryption_mode == "SSE-KMS",
      aws_glue_security_configuration.this[0].encryption_configuration[0].job_bookmarks_encryption[0].job_bookmarks_encryption_mode == "CSE-KMS",
    ])
    error_message = "S3, CloudWatch and bookmarks must all use the key."
  }
  assert {
    condition     = aws_glue_job.this.security_configuration == "orders-db-test" && aws_glue_crawler.this[0].security_configuration == "orders-db-test"
    error_message = "Job and crawler must use the created configuration."
  }
  assert {
    condition     = aws_glue_job.this.default_arguments["--s3_kms_key_arn"] == var.kms_key_arn
    error_message = "The extractor must encrypt its own writes (boto3 is not a Glue sink)."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.this[0].statement : s.resources if s.sid == "UseDataKey"]) == toset([var.kms_key_arn])
    error_message = "The role must be able to use the key, and only that key."
  }
  assert {
    condition     = contains(one([for s in data.aws_iam_policy_document.this[0].statement : s.actions if s.sid == "GlueLogs"]), "logs:AssociateKmsKey")
    error_message = "Encrypted logs need logs:AssociateKmsKey."
  }
}

run "existing_security_configuration" {
  command = plan

  variables {
    security_configuration = "shared-kms"
  }

  assert {
    condition     = length(aws_glue_security_configuration.this) == 0 && aws_glue_job.this.security_configuration == "shared-kms"
    error_message = "An existing configuration must be attached, not created."
  }
}

run "security_configuration_needs_key" {
  command = plan

  variables {
    create_security_configuration = true
  }

  expect_failures = [aws_glue_job.this]
}

run "security_configuration_create_or_existing" {
  command = plan

  variables {
    kms_key_arn                   = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    create_security_configuration = true
    security_configuration        = "shared-kms"
  }

  expect_failures = [aws_glue_job.this]
}

run "kms_key_must_be_an_arn" {
  command = plan

  variables {
    kms_key_arn = "alias/lake"
  }

  expect_failures = [var.kms_key_arn]
}

run "incremental_default_state_path" {
  command = plan

  variables {
    extract_incremental = { "public.orders" = "updated_at" }
  }

  assert {
    condition     = jsondecode(aws_glue_job.this.default_arguments["--incremental"]) == { "public.orders" = "updated_at" }
    error_message = "Incremental tables must reach the extractor."
  }
  assert {
    condition     = aws_glue_job.this.default_arguments["--state_path"] == "s3://scripts-bucket/scripts/jobs/orders-db-test/state/" && output.state_s3_path == "s3://scripts-bucket/scripts/jobs/orders-db-test/state/"
    error_message = "State defaults to the job's scripts prefix, outside the crawler target."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.this[0].statement : s.resources if s.sid == "ReadWriteWatermarks"]) == toset(["arn:aws:s3:::scripts-bucket/scripts/jobs/orders-db-test/state/*"])
    error_message = "The role may write watermarks only under the state prefix."
  }
}

run "incremental_custom_state_path" {
  command = plan

  variables {
    extract_incremental   = { "public.orders" = "updated_at" }
    extract_state_s3_path = "s3://state-bucket/glue/"
  }

  assert {
    condition     = aws_glue_job.this.default_arguments["--state_path"] == "s3://state-bucket/glue/"
    error_message = "Custom state path must be used."
  }
}

run "incremental_needs_bundled_extractor" {
  command = plan

  variables {
    script_s3_key       = "custom/job.py"
    extract_incremental = { "public.orders" = "updated_at" }
  }

  expect_failures = [aws_glue_job.this]
}

run "incremental_needs_column" {
  command = plan

  variables {
    extract_incremental = { "public.orders" = " " }
  }

  expect_failures = [var.extract_incremental]
}

run "source_load_controls" {
  command = plan

  variables {
    extract_fetchsize            = 20000
    extract_fetchsize_overrides  = { "public.orders" = 500 }
    extract_statement_timeout_ms = 60000
  }

  assert {
    condition = alltrue([
      aws_glue_job.this.default_arguments["--fetchsize"] == "20000",
      jsondecode(aws_glue_job.this.default_arguments["--fetchsize_overrides"]) == { "public.orders" = 500 },
      aws_glue_job.this.default_arguments["--statement_timeout_ms"] == "60000",
      aws_glue_job.this.default_arguments["--application_name"] == "orders-db-test",
    ])
    error_message = "Chunk size, per-table overrides, statement timeout and application name must reach the extractor."
  }
}

run "statement_timeout_floor" {
  command = plan

  variables {
    extract_statement_timeout_ms = 10
  }

  expect_failures = [var.extract_statement_timeout_ms]
}
