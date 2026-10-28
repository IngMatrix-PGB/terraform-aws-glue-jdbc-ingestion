# terraform-aws-glue-jdbc-ingestion

[![CI](https://github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion)](https://github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion/releases)
[![License](https://img.shields.io/github/license/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion)](LICENSE)
[![Terraform Registry](https://img.shields.io/badge/Terraform_Registry-glue--jdbc--ingestion-7B42BC?logo=terraform)](https://registry.terraform.io/modules/IngMatrix-PGB/glue-jdbc-ingestion/aws/latest)

Terraform module that ingests a JDBC source into S3 as Parquet with AWS Glue:
one job per source, with its connection, least-privilege role, schedule,
optional crawler and failure alerts. It ships a tested PostgreSQL extractor
for Glue Python shell, so a database can be landed with a dozen lines of HCL.

![Architecture: a scheduled Glue Python shell job reads PostgreSQL through a server-side cursor and writes Parquet to S3; a chained crawler updates the Glue Data Catalog for Athena, and EventBridge sends failures to SNS](https://raw.githubusercontent.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion/main/docs/images/architecture.png)

<sub>Source: [`docs/images/architecture.mmd`](https://github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion/blob/main/docs/images/architecture.mmd) (regenerate with `mermaid-cli`).</sub>

Highlights:

- **Cheap by default:** a 0.0625 DPU Python shell job instead of Spark, about
  a tenth of the smallest Spark job, with FLEX available for Spark sources.
- **Safe with credentials and data:** secrets only by reference, TLS without
  plaintext fallback, read-only sessions, least-privilege IAM, optional KMS
  for objects, logs and bookmarks.
- **Gentle on the source:** chunked server-side cursors, per-table chunk
  sizes, statement timeouts, incremental tables by watermark, and an
  `application_name` per job so every slow query has an owner.
- **Readers never see a half-written table:** full dumps write the new
  snapshot before deleting the old one; a failed table keeps its data.
- **Tested for real:** `terraform test` on the oldest and newest supported
  Terraform, the extractor against PostgreSQL 16 with TLS, and the grants
  submodule applied to a live database in CI.

```hcl
module "orders_db" {
  source  = "IngMatrix-PGB/glue-jdbc-ingestion/aws"
  version = "0.4.2" # x-release-please-version

  name           = "orders-db-prd"
  scripts_bucket = "my-glue-scripts"
  output_s3_path = "s3://my-datalake/raw/orders-db/"

  # A reader endpoint, not the writer: dumps are long sequential reads.
  jdbc_url   = "jdbc:postgresql://orders-ro.example.internal:5432/orders"
  secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:orders/reader-AbCdEf"

  subnet_id          = "subnet-0123456789abcdef0"
  security_group_ids = ["sg-0123456789abcdef0"]

  extract_discover = true                 # every table of public
  python_modules   = ["pg8000==1.31.5"]   # or extra_py_files without internet

  create_trigger   = true
  trigger_schedule = "cron(0 9 * * ? *)"  # daily; see "Operating the source"
}
```

Examples: [`examples/minimal`](examples/minimal) (one database) and
[`examples/complete`](examples/complete) (several sources with `for_each`,
chained crawlers, alerts and a Spark job with a custom script).

## What it creates

| Resource | When |
|---|---|
| `aws_glue_job` (Python shell or Spark) | always |
| `aws_s3_object` with the script | unless `script_s3_key` points at an existing one |
| `aws_glue_connection` (JDBC, network wiring only) | `create_connection` (default) |
| `aws_iam_role` + inline policy scoped to this job | `create_iam_role` (default) |
| `aws_glue_trigger` (schedule) | `create_trigger` |
| `aws_glue_crawler` + conditional triggers | `create_crawler`, `chain_crawler` |
| EventBridge rules to SNS for failures | `alerts_sns_topic_arn` |
| `aws_glue_security_configuration` (KMS for S3, logs, bookmarks) | `create_security_configuration` |

## Design decisions

These come from running this pattern in production; each one fixed a real
failure or cost problem.

- **Credentials never leave Secrets Manager.** The job gets `--secret_id` and
  reads the secret at runtime. Job arguments are readable by anyone with
  `glue:GetJob`, and `USERNAME`/`PASSWORD` connection properties end up in
  plain text in Terraform state, so the module rejects them. The connection
  references the secret through `SECRET_ID` and only provides the VPC wiring.
- **Python shell by default.** A table dump does not need Spark: a 0.0625 DPU
  Python shell job costs about a tenth of the smallest Spark job. Use
  `job_type = "glueetl"` for real transformations. Switching types replaces the
  job (an in-place update fails in the Glue API).
- **One writer per prefix.** Each run replaces (or appends to) a table's
  folder, so two concurrent runs would race and duplicate rows.
  `max_concurrent_runs` defaults to 1; callers such as Step Functions should
  retry `ConcurrentRunsExceeded`.
- **Explicit timeout and failure alerts.** `job_timeout` defaults to 60
  minutes instead of Glue's 48 hours, so a stuck run ends in `TIMEOUT`, which
  the EventBridge rule reports with `FAILED` and `ERROR`.
- **Data and schema refresh separately.** The job overwrites the Parquet files
  and Athena reads them right away; the crawler is only needed when the schema
  changes. A crawler run bills at least 10 minutes, so run it weekly
  (`crawler_schedule`) or chain it to the job (`chain_crawler`), not every 30
  minutes. Chained crawlers only fire for runs started by Glue triggers.
- **Crawler that does not surprise you.** `MergeNewColumns` keeps table
  properties set outside the crawler, `delete_behavior = LOG` never drops
  tables, and `crawler_table_level` stops Glue from collapsing a prefix that
  has a single table into one table with `partition_0`.
- **Least privilege.** The role can read its script and the secret, write only
  its output prefix (and the watermark prefix for incremental tables) and
  update only its catalog database. Delete permissions on the catalog are
  granted only when the schema change policy can delete.
- **Encryption at rest is one key away.** With `kms_key_arn` the extractor
  writes every object with SSE-KMS, and `create_security_configuration = true`
  (or an existing `security_configuration`) encrypts the job's and crawler's
  CloudWatch Logs and bookmarks. A security configuration's S3 setting only
  covers Glue Spark sinks, which is why the extractor sets SSE itself. The key
  policy must allow `logs.<region>.amazonaws.com` (see `examples/complete`).

## Bundled PostgreSQL extractor

[`scripts/pg_extractor.py`](scripts/pg_extractor.py) is used when neither
`script_local_path` nor `script_s3_key` is set.

- **Modes:** `extract_tables = ["public.orders", "billing.invoices"]`, or
  `extract_discover = true` for every table of `extract_schema` (migration
  bookkeeping tables such as `schema_migrations` are always skipped).
- **Layout:** `<output_s3_path>/<table>/part-<run>-NNNNN.snappy.parquet`;
  tables outside `public` become `<schema>_<table>`. An empty table still
  gets one empty part so the crawler sees its columns.
- **Replacing a table (write-then-delete):** new parts are written next to
  the old ones and the old objects are deleted only after the last part is
  written. A table that fails keeps its previous snapshot and its new parts
  are removed, so readers never see it empty or partial. During the delete
  calls (well under a second for a few hundred parts) a query can see old and
  new rows together; S3 has no atomic rename, so true atomicity needs a table
  format such as Iceberg.
- **Incremental tables:** `extract_incremental = { "public.payments" =
  "created_at" }` appends the rows whose watermark is greater than the last
  value seen to `<table>/ingest_date=YYYY-MM-DD/`. Watermarks are JSON files
  under `extract_state_s3_path` (default: `state/` next to the script). The
  first run, or a run after the column changes, is a full reload that
  replaces the folder. Delivery is at-least-once and rows are new versions,
  not upserts: deduplicate by primary key downstream. Rows with a NULL
  watermark are only read by the full reload, and a transaction that commits
  a value lower than one already read is missed: use a column set at insert
  time or a sequence, index it, and schedule an occasional full reload by
  deleting the state file if that matters. Each day is a new partition, which
  Athena only sees once it is in the catalog: chain the crawler
  (`chain_crawler`) or use partition projection on `ingest_date`.
- **Memory:** a server-side cursor reads `--fetchsize` rows (default 50,000)
  at a time, one Parquet part per chunk.
- **Safety:** read-only session, TLS always (`require`, or `verify-full`
  with `--ssl_root_cert`) and no plaintext fallback. With a secret that has
  no password, the extractor uses RDS IAM authentication
  (`rds_iam_auth_resource_arns`).
- **Failures:** a failing table does not stop the rest; the run fails at the
  end and lists them. In discover mode, tables without `SELECT` are skipped
  and reported, and their existing data is left alone.
- **Types:** integers, floats, booleans, dates, timestamps (UTC for
  `timestamptz`), `bytea` and `numeric(p,s)` keep their types. Unconstrained
  `numeric`, arrays, `json`/`jsonb` and anything else become strings
  (JSON-encoded where it applies), because a fixed decimal scale would round
  silently.
- **Driver:** pg8000 (pure Python, SCRAM-SHA-256). Install it with
  `python_modules = ["pg8000==1.31.5"]` (needs a NAT) or upload the wheels and
  pass them in `extra_py_files`:
  `pip download pg8000==1.31.5 --only-binary=:all: --python-version 3.9 -d libs/`.

Known limits are tracked in [docs/TECH-DEBT.md](docs/TECH-DEBT.md).

## Operating the source

Lessons from running these dumps against production databases.

- **Schedule by who reads the data, not by habit.** A full dump every 30
  minutes is 48 full scans a day. Before going below daily, check that
  someone reads it that often (Athena query history, BI tool usage). In one
  production cluster, 30-minute dumps that nobody read were all of the
  queries slower than 1 s on the reader and kept it scaled up; moving them to
  daily removed that load. Use `extract_incremental` for big tables that do
  need fresh data.
- **Read from a replica that is not the first failover target.** Point
  `jdbc_url` at a reader (or custom) endpoint. On Aurora, give the instance
  that serves the dumps a lower failover priority (higher `promotion_tier`)
  than the one meant to take over writes, so a failover never lands on the
  instance that is busy with a dump.
- **Make the load attributable.** The extractor sets `application_name` to
  the job name, so `pg_stat_activity`, `pg_stat_statements` and Performance
  Insights show which job is running a slow `FETCH`, even when every job uses
  the same database user.
- **Bound each chunk.** `extract_statement_timeout_ms` caps every `FETCH`;
  `extract_fetchsize` and `extract_fetchsize_overrides` keep memory flat for
  tables with wide rows (a chunk is held in memory, about 1 GB at 0.0625 DPU).
- **Grant through Terraform, for the role that creates the tables.** A table
  added to a job without its `GRANT` fails in production with "permission
  denied". [`modules/postgresql-grants`](modules/postgresql-grants) grants
  SELECT on what exists and default privileges for future tables. Default
  privileges apply per creating role: list the service's migration role in
  `table_owners`, not the admin user, or they never fire.

## Network prerequisites

With `create_connection = true` the job runs in your subnet, which needs:

- a route to the database;
- an S3 gateway endpoint (script, output and libraries);
- a Secrets Manager interface endpoint or a NAT;
- a NAT if you use `python_modules`;
- a security group with a self-referencing all-TCP inbound rule (a Glue requirement).

For sources reachable without a VPC set `create_connection = false`. To keep
the connection but run the job outside the VPC (for example a job that calls
Athena), set `attach_connection_to_job = false`.

## Development

```bash
pre-commit install                       # fmt, validate, tflint, docs, ruff
terraform test                           # plan-only tests, mocked provider
docker run -d --name pgx -e POSTGRES_PASSWORD=admin -p 55432:5432 postgres:16 \
  -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
pip install -r tests/python/requirements.txt
PG_PORT=55432 AWS_DEFAULT_REGION=us-east-1 pytest tests/python
docker run -d --name pgg -e POSTGRES_PASSWORD=admin -p 55433:5432 postgres:16
PGHOST=localhost PGPORT=55433 PGUSER=postgres PGPASSWORD=admin tests/grants/run.sh
docker run -d -p 4566:4566 floci/floci:2.3.0   # local AWS emulator
tests/floci/run.sh                              # apply, empty plan, inspect, destroy
```

`tests/floci` applies the module with every option on, creating all its
dependencies in the same run, to [Floci](https://floci.io). It catches what a
mocked plan cannot (values unknown until apply in `count`, API shapes,
idempotency), but Floci does not run the Glue script or enforce IAM and KMS,
so it does not replace an apply in a real account.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the same
checks plus Checkov. Upgrading from 0.1.x: see [CHANGELOG.md](CHANGELOG.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9.0 |
| aws | >= 6.0, < 7.0 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 6.0, < 7.0 |
| terraform | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.crawler_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.job_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.crawler_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.job_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_glue_connection.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_connection) | resource |
| [aws_glue_crawler.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_crawler) | resource |
| [aws_glue_job.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_job) | resource |
| [aws_glue_security_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_security_configuration) | resource |
| [aws_glue_trigger.crawler_on_job_failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_trigger) | resource |
| [aws_glue_trigger.crawler_on_job_success](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_trigger) | resource |
| [aws_glue_trigger.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_trigger) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_object.script](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [terraform_data.job_command](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| jdbc\_url | JDBC URL of the source, e.g. `jdbc:postgresql://host:5432/db`. Used by the Glue connection and passed to the job as `--jdbc_url`. | `string` | n/a | yes |
| name | Base name for the job and its connection, crawler, triggers, role and alert rules. Include the environment (e.g. `orders-db-prd`) so two environments in one account never collide. | `string` | n/a | yes |
| output\_s3\_path | S3 prefix the job writes to (`s3://bucket/prefix/`). Passed as `--output_path_base`; scopes the role's write access and is the crawler's default target. | `string` | n/a | yes |
| scripts\_bucket | S3 bucket that holds the job script. | `string` | n/a | yes |
| secret\_arn | Secrets Manager secret ARN with the source credentials (`username`/`password`, or `username` alone for RDS IAM auth). The job resolves it at runtime from `--secret_id`; credentials never reach job arguments, connection properties or Terraform state. | `string` | n/a | yes |
| alerts\_sns\_topic\_arn | SNS topic for EventBridge alerts when the job ends in FAILED/TIMEOUT/ERROR or the crawler fails. Its policy must allow `events.amazonaws.com` to publish. Null creates no alerts. | `string` | `null` | no |
| attach\_connection\_to\_job | Attach the connection to the job. Set false to keep the connection but run the job outside the VPC (e.g. Athena runners). | `bool` | `true` | no |
| availability\_zone | Availability zone of `subnet_id`. Looked up from the subnet when null. | `string` | `null` | no |
| chain\_crawler | Start the crawler from a conditional trigger when the job SUCCEEDS, instead of a cron. Conditional triggers fire only for runs started by Glue triggers, not for StartJobRun from Step Functions or the CLI. | `bool` | `false` | no |
| connection\_name | Glue connection name. Defaults to `name`. | `string` | `null` | no |
| connection\_properties | Extra connection properties merged over `JDBC_CONNECTION_URL` and `SECRET_ID` (e.g. `JDBC_ENFORCE_SSL`). USERNAME and PASSWORD are rejected: they would be stored in plain text in state and returned by `glue:GetConnection`. | `map(string)` | `{}` | no |
| crawler\_database\_name | Glue Catalog database for the crawler (must exist). Required when `create_crawler` is true. | `string` | `null` | no |
| crawler\_exclusions | Glob patterns the crawler skips. | `list(string)` | ```[ "**/_SUCCESS", "**/_temporary/**" ]``` | no |
| crawler\_name | Crawler name. Defaults to `name`. | `string` | `null` | no |
| crawler\_on\_job\_failure | With `chain_crawler`, also start the crawler when the job FAILS (for jobs that write independent tables and fail if any one fails). Glue rejects two conditions on the same job in one predicate, so this is a second trigger. | `bool` | `false` | no |
| crawler\_s3\_target\_path | Crawler target. Defaults to `output_s3_path`. | `string` | `null` | no |
| crawler\_schedule | Own cron for the crawler. Weekly is usually enough (a crawler run bills at least 10 minutes). Ignored when `chain_crawler` is true. | `string` | `null` | no |
| crawler\_schema\_change\_delete\_behavior | LOG (default: never drop tables that disappear), DEPRECATE\_IN\_DATABASE or DELETE\_FROM\_DATABASE. | `string` | `"LOG"` | no |
| crawler\_schema\_change\_update\_behavior | UPDATE\_IN\_DATABASE (update tables in place) or LOG. | `string` | `"UPDATE_IN_DATABASE"` | no |
| crawler\_table\_level | Folder depth where the crawler creates tables (bucket = 1). Set it to the depth of `<prefix>/<table>/` so a prefix with a single table is not collapsed into one table with `partition_0`. Null keeps Glue's grouping. | `number` | `null` | no |
| create\_alerts | Create the EventBridge alert rules. Null infers it from `alerts_sns_topic_arn`, which only works when the ARN is known at plan time: set true when the topic is created in the same apply. | `bool` | `null` | no |
| create\_connection | Create a JDBC Glue connection. It only provides the network wiring (ENIs in your VPC) and references the secret through `SECRET_ID`. Set false for sources reachable without a VPC. | `bool` | `true` | no |
| create\_crawler | Create a crawler that catalogs the output. Only needed when the schema changes: the job overwrites the data and Athena reads it right away. | `bool` | `false` | no |
| create\_iam\_role | Create a least-privilege role for the job and crawler. Set false and pass `iam_role_arn` to bring your own. | `bool` | `true` | no |
| create\_security\_configuration | Create a Glue security configuration (SSE-KMS for S3 and CloudWatch Logs, CSE-KMS for bookmarks) with `kms_key_arn` and attach it to the job and the crawler. Glue writes to S3 only through Spark sinks: a script writing with boto3 (like the bundled extractor) must set SSE itself. | `bool` | `false` | no |
| create\_trigger | Create a Glue trigger for the job. | `bool` | `false` | no |
| default\_arguments | Extra job arguments, merged last (they override the module's). | `map(string)` | `{}` | no |
| execution\_class | `STANDARD` or `FLEX` (cheaper, delayed start). Applies to glueetl only; the API rejects it for pythonshell. | `string` | `null` | no |
| extra\_py\_files | S3 URIs of wheels or .py files for `--extra-py-files`. Use it for pg8000 when the subnet has no internet access (see README). | `list(string)` | `[]` | no |
| extract\_discover | Bundled extractor only: dump every base table of `extract_schema` instead of `extract_tables`. Tables without SELECT are skipped and reported; other failures fail the run after the remaining tables are written. | `bool` | `false` | no |
| extract\_exclude\_tables | Bundled extractor only: tables to skip in discover mode, in addition to migration bookkeeping tables (`schema_migrations`, `flyway_schema_history`, ...). | `list(string)` | `[]` | no |
| extract\_fetchsize | Bundled extractor only: rows per chunk and Parquet part. A chunk is held in memory (about 1 GB at 0.0625 DPU), so lower it, or use `max_capacity = 1`, for wide rows. | `number` | `50000` | no |
| extract\_fetchsize\_overrides | Bundled extractor only: per-table chunk size, as `{ "schema.table" = rows }`, for the few tables with wide rows (large JSON, bytea) so the rest keep the faster default. | `map(number)` | `{}` | no |
| extract\_incremental | Bundled extractor only: tables appended incrementally, as `{ "schema.table" = "watermark_column" }`. Each run writes the rows whose watermark is greater than the last one seen to `<table>/ingest_date=YYYY-MM-DD/`; the first run is a full reload. The column must be an integer, numeric, date or timestamp. Delivery is at-least-once and rows are new versions, not upserts: deduplicate by primary key downstream. | `map(string)` | `{}` | no |
| extract\_schema | Bundled extractor only: schema scanned in discover mode. | `string` | `"public"` | no |
| extract\_ssl\_mode | Bundled extractor only: `require` (TLS without certificate verification, like libpq sslmode=require) or `verify-full` (needs `--ssl_root_cert` in default\_arguments). There is no plaintext fallback. | `string` | `"require"` | no |
| extract\_state\_s3\_path | Bundled extractor only: where incremental watermarks are stored (`s3://bucket/prefix/`, one JSON object per table). Defaults to `state/` under this job's scripts prefix, outside the crawler target. | `string` | `null` | no |
| extract\_statement\_timeout\_ms | Bundled extractor only: PostgreSQL `statement_timeout` for the session, applied to each FETCH. Caps how long one chunk can load the source (a table that hits it fails and keeps its previous snapshot). Null keeps the server default. | `number` | `null` | no |
| extract\_tables | Bundled extractor only: tables to dump, as `schema.table` (schema defaults to public). Ignored when `extract_discover` is true. | `list(string)` | `[]` | no |
| glue\_version | Glue version. Defaults to `3.0` for pythonshell and `4.0` for glueetl. | `string` | `null` | no |
| iam\_additional\_read\_s3\_paths | Extra `s3://bucket/prefix/` paths the role may read (e.g. custom libraries, CA bundles). | `list(string)` | `[]` | no |
| iam\_role\_arn | Existing role for the job and crawler. Required when `create_iam_role` is false. | `string` | `null` | no |
| iam\_role\_permissions\_boundary | Permissions boundary ARN for the created role. | `string` | `null` | no |
| job\_timeout | Job timeout in minutes. Keep it explicit: a stuck job ends in TIMEOUT (which the alert rule catches) instead of running for Glue's 48 h default. | `number` | `60` | no |
| job\_type | `pythonshell` (0.0625 or 1 DPU; right for most table dumps) or `glueetl` (Spark, sized with workers). Changing it replaces the job. | `string` | `"pythonshell"` | no |
| kms\_key\_arn | Customer managed KMS key for data at rest: the bundled extractor writes Parquet and watermarks with SSE-KMS, and a created security configuration uses it for S3, CloudWatch Logs and job bookmarks. Grants the created role encrypt/decrypt on it. The key policy must also allow `logs.<region>.amazonaws.com` when CloudWatch encryption is on. | `string` | `null` | no |
| max\_capacity | DPUs for pythonshell jobs: 0.0625 or 1. Ignored for glueetl. | `number` | `0.0625` | no |
| max\_concurrent\_runs | Concurrent runs allowed. Keep 1 when the job overwrites a prefix: two writers on the same prefix duplicate rows. Extra StartJobRun calls fail with ConcurrentRunsExceeded, so callers (Step Functions) should retry. | `number` | `1` | no |
| max\_retries | Automatic retries after a failed run. | `number` | `0` | no |
| number\_of\_workers | Spark worker count for glueetl jobs (minimum 2). Ignored for pythonshell. | `number` | `2` | no |
| python\_modules | pip requirements for `--additional-python-modules` (e.g. `pg8000==1.31.5`). Needs internet access (NAT) from the subnet. | `list(string)` | `[]` | no |
| python\_version | Python version. Defaults to `3.9` for pythonshell and `3` for glueetl. | `string` | `null` | no |
| pythonshell\_library\_set | `--library-set` for pythonshell 3.9 jobs. `analytics` preloads pyarrow, pandas and boto3. Null omits it. | `string` | `"analytics"` | no |
| rds\_iam\_auth\_resource\_arns | `rds-db:connect` resources (`arn:aws:rds-db:<region>:<account>:dbuser:<resource-id>/<user>`) for IAM database authentication. Empty when the secret carries a password. | `list(string)` | `[]` | no |
| script\_local\_path | Local path of a custom script to upload. Leave both this and `script_s3_key` null to use the bundled PostgreSQL extractor (`scripts/pg_extractor.py`). | `string` | `null` | no |
| script\_s3\_key | S3 key of a script that already exists in `scripts_bucket` (nothing is uploaded). Takes precedence over `script_local_path`. | `string` | `null` | no |
| scripts\_prefix | S3 prefix for uploaded scripts. The key is `<scripts_prefix>/<name>/<file>`. | `string` | `"scripts/jobs"` | no |
| secret\_kms\_key\_arn | Customer managed KMS key that encrypts the secret, if any. Grants `kms:Decrypt` to the created role. | `string` | `null` | no |
| security\_configuration | Name of an existing Glue security configuration to attach to the job and the crawler instead of creating one. | `string` | `null` | no |
| security\_group\_ids | Security groups for the connection ENIs. Glue requires one of them to allow all TCP from itself (self-referencing rule). | `list(string)` | `[]` | no |
| subnet\_id | Subnet for the connection ENIs. Required when `create_connection` is true. It needs a route to S3 (gateway endpoint) and to Secrets Manager (interface endpoint or NAT). | `string` | `null` | no |
| tags | Tags for every taggable resource. Prefer provider `default_tags` for organization-wide tags. | `map(string)` | `{}` | no |
| trigger\_enabled | Whether the trigger is active. | `bool` | `true` | no |
| trigger\_name | Trigger name. Defaults to `name`. | `string` | `null` | no |
| trigger\_schedule | Cron for SCHEDULED triggers, e.g. `cron(0 3 * * ? *)` (UTC). | `string` | `null` | no |
| trigger\_type | ON\_DEMAND or SCHEDULED. | `string` | `"SCHEDULED"` | no |
| worker\_type | Spark worker type for glueetl jobs. Ignored for pythonshell. | `string` | `"G.1X"` | no |

## Outputs

| Name | Description |
|------|-------------|
| connection\_name | Glue connection name (null when not created). |
| crawler\_name | Crawler name (null when not created). |
| job\_arn | Glue job ARN. |
| job\_name | Glue job name. |
| output\_s3\_path | S3 prefix the job writes to. |
| role\_arn | Role used by the job and the crawler. |
| role\_name | Name of the created role (null when `create_iam_role` is false). |
| script\_s3\_uri | S3 URI of the job script. |
| security\_configuration\_name | Glue security configuration attached to the job and the crawler, if any. |
| state\_s3\_path | Where the bundled extractor stores incremental watermarks (null without `extract_incremental`). |
| trigger\_name | Schedule trigger name (null when not created). |
<!-- END_TF_DOCS -->

## License

Apache-2.0. See [LICENSE](LICENSE).
