# Applied against a throwaway PostgreSQL by tests/grants/run.sh. The provider
# reads PGHOST, PGPORT, PGUSER, PGPASSWORD and PGSSLMODE from the environment.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.25.0"
    }
  }
}

provider "postgresql" {
  database  = "grants_test"
  superuser = false
}

module "grants" {
  source = "../../modules/postgresql-grants"

  database     = "grants_test"
  role         = "lake_reader"
  schemas      = ["public", "app"]
  table_owners = ["app_owner"]
}
