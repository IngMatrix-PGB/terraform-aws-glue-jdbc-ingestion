#!/usr/bin/env bash
# Applies modules/postgresql-grants to a local PostgreSQL and checks the
# privileges it leaves, including tables created after the apply.
#   PGHOST=localhost PGPORT=55433 PGUSER=postgres PGPASSWORD=admin tests/grants/run.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGSSLMODE="${PGSSLMODE:-disable}"
psql_() { psql -v ON_ERROR_STOP=1 -qtAX "$@"; }

psql_ -d postgres <<'SQL'
DROP DATABASE IF EXISTS grants_test;
DROP ROLE IF EXISTS lake_reader;
DROP ROLE IF EXISTS app_owner;
DROP ROLE IF EXISTS other_owner;
CREATE ROLE lake_reader NOLOGIN;
CREATE ROLE app_owner NOLOGIN;
CREATE ROLE other_owner NOLOGIN;
CREATE DATABASE grants_test;
SQL
psql_ -d grants_test <<'SQL'
GRANT CREATE ON SCHEMA public TO app_owner, other_owner;
CREATE SCHEMA app AUTHORIZATION app_owner;
SET ROLE app_owner;
CREATE TABLE public.existing (id int);
CREATE TABLE app.items (id int);
SQL

terraform init -input=false -upgrade >/dev/null
terraform apply -input=false -auto-approve >/dev/null
trap 'terraform destroy -input=false -auto-approve >/dev/null' EXIT

psql_ -d grants_test <<'SQL'
SET ROLE app_owner;
CREATE TABLE public.created_later (id int);
CREATE TABLE app.created_later (id int);
SET ROLE other_owner;
CREATE TABLE public.not_covered (id int);
SQL

check() {
  got=$(psql_ -d grants_test -c "SELECT has_table_privilege('lake_reader', '$1', 'SELECT')")
  if [ "$got" != "$2" ]; then
    echo "FAIL: SELECT on $1 is $got, expected $2" >&2
    exit 1
  fi
  echo "ok   SELECT on $1 = $2"
}
check public.existing t
check app.items t
check public.created_later t
check app.created_later t
# Created by a role not in table_owners: default privileges do not reach it.
check public.not_covered f
# A re-apply fixes it (GRANT ON ALL TABLES re-grants on drift).
terraform apply -input=false -auto-approve >/dev/null
check public.not_covered t
