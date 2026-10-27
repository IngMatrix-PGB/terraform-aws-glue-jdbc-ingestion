# Changelog

All notable changes to this module. Versions follow [SemVer](https://semver.org/);
while the major version is 0, minor versions may break the interface.

## [0.2.0] - Unreleased

### Breaking

- The module moved from `modules/matrix-datalake-jdbc-glue` to the repository
  root (Terraform Registry layout). Update `source`, e.g.
  `github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion?ref=v0.2.0`.
  Resource addresses inside the module did not change, so no `moved` blocks are
  needed for the job, connection, crawler, trigger or script object.
- Credentials: `connection_properties` no longer accepts `USERNAME`/`PASSWORD`.
  Pass `jdbc_url` and `secret_arn`; the connection gets `SECRET_ID` and the job
  gets `--secret_id`. Applying updates the connection in place and removes the
  password from Terraform state.
- New required inputs: `jdbc_url`, `secret_arn`, `output_s3_path`.
- `iam_role_arn` is now optional: the module creates a scoped role unless
  `create_iam_role = false`.
- Defaults changed: `job_type = "pythonshell"` (was always Spark), `create_crawler = false`
  (was true and failed without a database), `max_retries = 0` (was 1; alerts
  fire on the first failure), `max_concurrent_runs = 1`, `trigger_type = "SCHEDULED"`.
- `connection_type` was removed (always `JDBC`).
- Requires Terraform >= 1.9 and AWS provider >= 6.0, < 7.0.

### Fixed

- `script_s3_key` without `script_local_path` left `script_location` empty and
  the plan failed.
- `create_crawler` defaulted to true with no database, so the module failed
  with only its required inputs.
- The example trigger names had no environment suffix (collisions between
  environments in one account) and passed an empty `--extra-jars`.

### Added

- Python shell jobs (0.0625/1 DPU), with a keeper that replaces the job when
  the command type changes.
- `execution_class` (FLEX) for Spark, explicit `job_timeout`, `max_concurrent_runs`.
- `attach_connection_to_job`; the availability zone is looked up from the subnet.
- Least-privilege IAM role (script, output prefix, secret, connection, catalog
  database; optional KMS and RDS IAM auth).
- Crawler: `chain_crawler`, `crawler_on_job_failure`, schema change policy,
  `MergeNewColumns`, `crawler_table_level`.
- EventBridge alerts to SNS for failed jobs and crawlers.
- Bundled PostgreSQL extractor (`scripts/pg_extractor.py`) with integration tests.
- `examples/minimal` and `examples/complete` (replace `examples/portfolio`).
- CI: fmt, validate, tflint, Checkov, `terraform test`, terraform-docs, ruff
  and extractor tests; pre-commit hooks.

## [0.1.0] - 2026-03-06

- Initial module: S3 script upload, JDBC connection, Glue job, optional crawler
  and trigger.
