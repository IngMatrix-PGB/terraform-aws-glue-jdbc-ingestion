# postgresql-grants

Read access for the role a Glue ingestion job logs in as: `USAGE` on the
schemas, `SELECT` on their tables (all, or a list), and default privileges so
tables created later are readable without another apply.

```hcl
provider "postgresql" {
  host      = "orders.cluster-example.us-east-1.rds.amazonaws.com"
  username  = "admin"          # must be a member of every table owner
  password  = var.admin_password
  sslmode   = "require"
  superuser = false            # RDS / Aurora admin is not a superuser
}

module "orders_db_grants" {
  source = "github.com/IngMatrix-PGB/terraform-aws-glue-jdbc-ingestion//modules/postgresql-grants?ref=v0.4.0" # x-release-please-version

  database     = "orders"
  role         = "lake_reader"           # the job secret's username
  schemas      = ["public"]
  table_owners = ["orders-svc-migrator"] # the role that runs migrations
}
```

Why `table_owners` matters: `ALTER DEFAULT PRIVILEGES FOR ROLE x` only covers
tables that `x` creates. Granting them for the admin user does nothing when
the service's migrations create the tables with their own role, and the job
fails on the first new table. On RDS the admin is not a superuser, so it must
be a member of each owner (`GRANT "orders-svc-migrator" TO admin;`) before
the apply.

The `SELECT` grant on all tables is also a safety net: the provider re-grants
on drift, so an apply fixes tables that slipped through. In discover mode the
extractor skips and reports tables without `SELECT` instead of failing.

This module never creates roles or passwords; manage the login role with the
secret that holds its credentials (or RDS IAM authentication).

[`tests/grants/run.sh`](../../tests/grants/run.sh) applies it to a real
PostgreSQL in CI and checks existing tables, tables created afterwards by a
listed owner, and a table by an unlisted owner (not covered until the next
apply).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9.0 |
| postgresql | >= 1.22, < 2.0 |

## Providers

| Name | Version |
|------|---------|
| postgresql | >= 1.22, < 2.0 |

## Resources

| Name | Type |
|------|------|
| [postgresql_default_privileges.select](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/default_privileges) | resource |
| [postgresql_grant.schema_usage](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/grant) | resource |
| [postgresql_grant.select](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/grant) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| database | Database the ingestion role reads. | `string` | n/a | yes |
| role | Existing PostgreSQL role the Glue job logs in as (the secret's username). This module only grants; it never creates roles or passwords. | `string` | n/a | yes |
| schemas | Schemas to grant USAGE and SELECT on. | `list(string)` | ```[ "public" ]``` | no |
| table\_owners | Roles that CREATE the tables (usually the one that runs the service's migrations, not the admin user). Each gets default privileges, so tables they create later are readable without another apply. The Terraform user must be a member of each owner (or superuser); default privileges for a role that never creates tables do nothing. | `list(string)` | `[]` | no |
| tables | Tables to grant SELECT on, as `schema.table`. Empty grants every existing table of `schemas` (what discover mode needs). | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| default\_privilege\_owners | Roles whose future tables the role can read. |
| schemas | Schemas the role can read. |
<!-- END_TF_DOCS -->
