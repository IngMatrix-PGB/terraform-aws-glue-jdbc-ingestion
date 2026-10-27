# Plan-only tests with a mocked AWS provider: no credentials, no resources.

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

run "pythonshell_defaults" {
  command = plan

  assert {
    condition     = aws_glue_job.this.command[0].name == "pythonshell" && aws_glue_job.this.command[0].python_version == "3.9"
    error_message = "Default job must be Python shell 3.9."
  }
  assert {
    condition     = aws_glue_job.this.max_capacity == 0.0625
    error_message = "Python shell must be sized with max_capacity only."
  }
  assert {
    condition     = aws_glue_job.this.execution_property[0].max_concurrent_runs == 1
    error_message = "One writer per prefix: max_concurrent_runs must default to 1."
  }
  assert {
    condition     = aws_glue_job.this.timeout == 60
    error_message = "Timeout must be explicit."
  }
  assert {
    condition     = endswith(aws_glue_job.this.command[0].script_location, "/orders-db-test/pg_extractor.py") && length(aws_s3_object.script) == 1
    error_message = "Bundled extractor must be uploaded and used."
  }
  assert {
    condition     = aws_glue_job.this.default_arguments["--secret_id"] == var.secret_arn && aws_glue_job.this.default_arguments["--discover"] == "true"
    error_message = "Job must get the secret reference and discover mode."
  }
  assert {
    condition     = length([for k in keys(aws_glue_job.this.default_arguments) : k if strcontains(lower(k), "password")]) == 0
    error_message = "No password-like job argument."
  }
  assert {
    condition     = aws_glue_connection.this[0].connection_properties["SECRET_ID"] == var.secret_arn && !contains(keys(aws_glue_connection.this[0].connection_properties), "PASSWORD")
    error_message = "Connection must reference the secret, never hold the password."
  }
  assert {
    condition     = aws_glue_connection.this[0].physical_connection_requirements[0].availability_zone == "us-east-1a"
    error_message = "AZ must be looked up from the subnet."
  }
  assert {
    condition     = length(aws_glue_job.this.connections) == 1
    error_message = "Connection must be attached by default."
  }
  assert {
    condition     = length(aws_iam_role.this) == 1 && length(aws_glue_crawler.this) == 0 && length(aws_glue_trigger.this) == 0 && length(aws_cloudwatch_event_rule.job_failed) == 0
    error_message = "Only the role is optional-on by default."
  }
  assert {
    condition     = contains([for s in data.aws_iam_policy_document.this[0].statement : s.sid], "VpcNetworkInterfaces")
    error_message = "VPC jobs need ENI permissions."
  }
}

# Regression: script_s3_key without script_local_path left script_location null.
run "existing_script_key" {
  command = plan

  variables {
    script_s3_key = "custom/job.py"
  }

  assert {
    condition     = aws_glue_job.this.command[0].script_location == "s3://scripts-bucket/custom/job.py"
    error_message = "script_location must use script_s3_key."
  }
  assert {
    condition     = length(aws_s3_object.script) == 0
    error_message = "Nothing is uploaded for an existing key."
  }
  assert {
    condition     = !contains(keys(aws_glue_job.this.default_arguments), "--discover")
    error_message = "Extractor arguments only apply to the bundled script."
  }
}

run "glueetl_custom_script" {
  command = plan

  variables {
    job_type          = "glueetl"
    script_local_path = "examples/complete/scripts/mysql_to_parquet.py"
    jdbc_url          = "jdbc:mysql://legacy.example.com:3306/legacy"
    worker_type       = "G.2X"
    number_of_workers = 4
    execution_class   = "FLEX"
  }

  assert {
    condition     = aws_glue_job.this.command[0].name == "glueetl" && aws_glue_job.this.glue_version == "4.0"
    error_message = "glueetl defaults to Glue 4.0."
  }
  assert {
    condition     = aws_glue_job.this.worker_type == "G.2X" && aws_glue_job.this.number_of_workers == 4
    error_message = "Spark must be sized with workers only."
  }
  assert {
    condition     = aws_glue_job.this.execution_class == "FLEX"
    error_message = "execution_class must pass through for Spark."
  }
  assert {
    condition     = aws_glue_job.this.default_arguments["--job-language"] == "python" && !contains(keys(aws_glue_job.this.default_arguments), "--library-set")
    error_message = "Spark arguments, not Python shell ones."
  }
}

run "outside_vpc" {
  command = plan

  variables {
    create_connection  = false
    subnet_id          = null
    security_group_ids = []
  }

  assert {
    condition     = length(aws_glue_connection.this) == 0 && length(aws_glue_job.this.connections) == 0
    error_message = "No connection outside the VPC."
  }
  assert {
    condition     = !contains([for s in data.aws_iam_policy_document.this[0].statement : s.sid], "VpcNetworkInterfaces")
    error_message = "No ENI permissions without a connection."
  }
}

run "connection_kept_but_detached" {
  command = plan

  variables {
    attach_connection_to_job = false
  }

  assert {
    condition     = length(aws_glue_connection.this) == 1 && length(aws_glue_job.this.connections) == 0
    error_message = "attach_connection_to_job = false keeps the connection off the job."
  }
}

run "bring_your_own_role" {
  command = plan

  variables {
    create_iam_role = false
    iam_role_arn    = "arn:aws:iam::123456789012:role/existing"
  }

  assert {
    condition     = length(aws_iam_role.this) == 0 && aws_glue_job.this.role_arn == "arn:aws:iam::123456789012:role/existing"
    error_message = "The given role must be used."
  }
}
