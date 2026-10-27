# Inputs that must be rejected at plan time.

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
  extract_discover   = true
}

run "rejects_password_in_connection_properties" {
  command = plan
  variables {
    connection_properties = { Password = "hunter2" }
  }
  expect_failures = [var.connection_properties]
}

run "rejects_partial_secret_arn" {
  command = plan
  variables {
    secret_arn = "orders/reader"
  }
  expect_failures = [var.secret_arn]
}

run "rejects_output_without_prefix" {
  command = plan
  variables {
    output_s3_path = "s3://lake-bucket"
  }
  expect_failures = [var.output_s3_path]
}

run "rejects_invalid_max_capacity" {
  command = plan
  variables {
    max_capacity = 2
  }
  expect_failures = [var.max_capacity]
}

# Regression: create_crawler without a database failed deep in the provider.
run "crawler_needs_database" {
  command = plan
  variables {
    create_crawler = true
  }
  expect_failures = [var.crawler_database_name]
}

run "chain_needs_crawler" {
  command = plan
  variables {
    chain_crawler = true
  }
  expect_failures = [aws_glue_job.this]
}

run "scheduled_trigger_needs_cron" {
  command = plan
  variables {
    create_trigger = true
  }
  expect_failures = [aws_glue_job.this]
}

run "bundled_extractor_needs_tables" {
  command = plan
  variables {
    extract_discover = false
  }
  expect_failures = [aws_glue_job.this]
}

run "bundled_extractor_is_pythonshell" {
  command = plan
  variables {
    job_type = "glueetl"
  }
  expect_failures = [aws_glue_job.this]
}

run "connection_needs_network" {
  command = plan
  variables {
    subnet_id          = null
    security_group_ids = []
  }
  expect_failures = [var.subnet_id, var.security_group_ids]
}

run "execution_class_is_spark_only" {
  command = plan
  variables {
    execution_class = "FLEX"
  }
  expect_failures = [aws_glue_job.this]
}

run "own_role_needs_arn" {
  command = plan
  variables {
    create_iam_role = false
  }
  expect_failures = [aws_glue_job.this]
}
