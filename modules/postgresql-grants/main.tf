################################################################################
# Read access for the ingestion role.
#
# GRANT ... ON ALL TABLES only covers tables that exist at apply time. New
# tables need default privileges, and those apply per creating role: ALTER
# DEFAULT PRIVILEGES FOR ROLE admin does nothing for tables created by the
# service's migration role. Hence one default-privileges resource per real
# owner in `table_owners`.
################################################################################

locals {
  # Tables per schema; schemas without explicit tables get ALL TABLES ([]).
  tables_by_schema = {
    for s in var.schemas : s => [
      for t in var.tables : split(".", t)[1] if split(".", t)[0] == s
    ]
  }

  owner_schema_pairs = {
    for pair in setproduct(var.table_owners, var.schemas) : "${pair[0]}/${pair[1]}" => {
      owner  = pair[0]
      schema = pair[1]
    }
  }
}

resource "postgresql_grant" "schema_usage" {
  for_each = toset(var.schemas)

  database    = var.database
  role        = var.role
  schema      = each.value
  object_type = "schema"
  privileges  = ["USAGE"]
}

resource "postgresql_grant" "select" {
  for_each = local.tables_by_schema

  database    = var.database
  role        = var.role
  schema      = each.key
  object_type = "table"
  privileges  = ["SELECT"]
  # Empty = every table in the schema. The provider re-grants on drift, so
  # an apply also fixes tables created without default privileges.
  objects = length(var.tables) == 0 ? [] : each.value

  lifecycle {
    precondition {
      condition     = length(var.tables) == 0 || length(each.value) > 0
      error_message = "Schema ${each.key} has no entry in tables; list its tables or remove it from schemas."
    }
  }
}

resource "postgresql_default_privileges" "select" {
  for_each = local.owner_schema_pairs

  database    = var.database
  role        = var.role
  owner       = each.value.owner
  schema      = each.value.schema
  object_type = "table"
  privileges  = ["SELECT"]
}
