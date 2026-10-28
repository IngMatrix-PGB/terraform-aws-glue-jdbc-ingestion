#!/usr/bin/env bash
# Applies modules/postgresql-grants to a local PostgreSQL the way it runs on
# RDS/Aurora: Terraform connects as an admin that is NOT a superuser (like the
# RDS master user, which only has rds_superuser). Checks that:
#   1. without membership in the table owner, the apply fails;
#   2. after GRANT <owner> TO admin, existing and future tables are readable;
#   3. a table created by an owner the admin is not a member of is not
#      covered, and makes the next apply fail until that owner is granted.
# PGHOST/PGPORT/PGUSER/PGPASSWORD must point at a real superuser, used only
# for the setup that a DBA would do by hand.
#   PGHOST=localhost PGPORT=55433 PGUSER=postgres PGPASSWORD=admin tests/grants/run.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGSSLMODE="${PGSSLMODE:-disable}"
SUPER_USER="$PGUSER"
SUPER_PASSWORD="$PGPASSWORD"
psql_() { PGUSER="$SUPER_USER" PGPASSWORD="$SUPER_PASSWORD" psql -v ON_ERROR_STOP=1 -qtAX "$@"; }
tf() { PGUSER=lake_admin PGPASSWORD=e2e-only terraform "$@" -input=false -no-color; }

psql_ -d postgres <<'SQL'
DROP DATABASE IF EXISTS grants_test;
DROP ROLE IF EXISTS lake_reader;
DROP ROLE IF EXISTS app_owner;
DROP ROLE IF EXISTS other_owner;
DROP ROLE IF EXISTS lake_admin;
CREATE ROLE lake_admin LOGIN PASSWORD 'e2e-only' NOSUPERUSER CREATEROLE CREATEDB;
CREATE ROLE lake_reader NOLOGIN;
CREATE ROLE app_owner NOLOGIN;
CREATE ROLE other_owner NOLOGIN;
CREATE DATABASE grants_test OWNER lake_admin;
SQL
psql_ -d grants_test <<'SQL'
GRANT CREATE ON SCHEMA public TO app_owner, other_owner;
CREATE SCHEMA app AUTHORIZATION app_owner;
SET ROLE app_owner;
CREATE TABLE public.existing (id int);
CREATE TABLE app.items (id int);
SQL

tf init -upgrade >/dev/null
trap 'tf destroy -auto-approve >/dev/null 2>&1 || true' EXIT

# 1. The admin is not a member of app_owner: default privileges for it fail.
if out=$(tf apply -auto-approve 2>&1); then
  echo "FAIL: apply succeeded without membership in app_owner" >&2
  exit 1
fi
echo "$out" | grep -qi "permission denied\|must be member\|must be able to SET ROLE" || {
  echo "$out" >&2
  echo "FAIL: apply failed for an unexpected reason" >&2
  exit 1
}
echo "ok   apply fails while the admin is not a member of the table owner"

# 2. What the README asks a DBA to run once per owner.
psql_ -d postgres -c 'GRANT app_owner TO lake_admin'
tf apply -auto-approve >/dev/null
echo "ok   apply succeeds after GRANT app_owner TO lake_admin"

psql_ -d grants_test <<'SQL'
SET ROLE app_owner;
CREATE TABLE public.created_later (id int);
CREATE TABLE app.created_later (id int);
RESET ROLE;
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
# 3. Default privileges do not reach an owner the admin is not a member of,
# and the next apply fails: a non-superuser provider grants itself each
# table owner to issue GRANT ON ALL TABLES, and the admin cannot do that.
check public.not_covered f
if out=$(tf apply -auto-approve 2>&1); then
  echo "FAIL: apply succeeded with a table of a foreign owner" >&2
  exit 1
fi
echo "$out" | grep -q 'permission denied to grant role "other_owner"' || {
  echo "$out" >&2
  exit 1
}
echo "ok   a table by an unlisted owner breaks the next apply"
psql_ -d postgres -c 'GRANT other_owner TO lake_admin'
tf apply -auto-approve >/dev/null
check public.not_covered t
