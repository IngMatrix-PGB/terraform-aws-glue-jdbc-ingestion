"""Integration tests for scripts/pg_extractor.py.

Needs a PostgreSQL with TLS enabled (see the `extractor` job in
.github/workflows/ci.yml for the docker command) and mocks AWS with moto:

    PG_PORT=55432 pytest tests/python

PG_NOSSL_PORT (optional) points at a server without TLS to check that the
extractor refuses to fall back to plaintext.
"""

import io
import json
import os
import sys
from decimal import Decimal
from pathlib import Path

import boto3
import pg8000.dbapi
import pyarrow.parquet as pq
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import pg_extractor  # noqa: E402

PG_HOST = os.environ.get("PG_HOST", "localhost")
PG_PORT = int(os.environ.get("PG_PORT", "5432"))
PG_ADMIN_PASSWORD = os.environ.get("PG_ADMIN_PASSWORD", "admin")
DB = "app"
BUCKET = "lake"
BASE = f"s3://{BUCKET}/raw/app/"


def admin_conn(database="postgres"):
    conn = pg8000.dbapi.connect(
        host=PG_HOST,
        port=PG_PORT,
        database=database,
        user="postgres",
        password=PG_ADMIN_PASSWORD,
        ssl_context=pg_extractor.ssl_context("require"),
    )
    conn.autocommit = True
    return conn


@pytest.fixture(scope="module", autouse=True)
def database():
    conn = admin_conn()
    cur = conn.cursor()
    cur.execute(f"DROP DATABASE IF EXISTS {DB}")
    cur.execute(f"CREATE DATABASE {DB}")
    cur.execute("DROP ROLE IF EXISTS reader")
    cur.execute("CREATE ROLE reader LOGIN PASSWORD 'reader'")
    conn.close()

    conn = admin_conn(DB)
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE orders (
          id bigint PRIMARY KEY,
          amount numeric(12,2),
          ratio numeric,
          paid boolean,
          created_at timestamptz,
          local_at timestamp,
          day date,
          tags text[],
          meta jsonb,
          ref uuid,
          note text
        );
        INSERT INTO orders
        SELECT g, g * 1.50, g / 3.0, g % 2 = 0,
               '2026-01-01 00:00:00+00'::timestamptz + g * interval '1 hour',
               '2026-01-01 00:00:00'::timestamp, '2026-01-01'::date,
               ARRAY['a', 'b'], jsonb_build_object('n', g),
               '00000000-0000-0000-0000-000000000001'::uuid, NULL
        FROM generate_series(1, 5) g;
        CREATE TABLE empty_table (id int, name text);
        CREATE TABLE schema_migrations (version bigint);
        CREATE TABLE "Mixed Case" (id int);
        INSERT INTO "Mixed Case" VALUES (1);
        CREATE TABLE secret_stuff (id int);
        CREATE SCHEMA billing;
        CREATE TABLE billing.invoices (id int);
        INSERT INTO billing.invoices VALUES (1), (2);
        GRANT USAGE ON SCHEMA billing TO reader;
        GRANT SELECT ON orders, empty_table, schema_migrations, "Mixed Case" TO reader;
        GRANT SELECT ON billing.invoices TO reader;
        CREATE TABLE events (id bigint, updated_at timestamptz);
        INSERT INTO events
        SELECT g, '2026-01-01 00:00:00+00'::timestamptz + g * interval '1 minute'
        FROM generate_series(1, 3) g;
        INSERT INTO events VALUES (99, NULL);
        GRANT SELECT ON events TO reader;
        """
    )
    conn.close()
    yield


@pytest.fixture()
def aws():
    with mock_aws():
        os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket=BUCKET)
        # Stale object from a previous run: must be gone after the dump.
        s3.put_object(Bucket=BUCKET, Key="raw/app/orders/part-old.snappy.parquet", Body=b"x")
        sm = boto3.client("secretsmanager")
        arn = sm.create_secret(
            Name="app/reader", SecretString=json.dumps({"username": "reader", "password": "reader"})
        )["ARN"]
        yield s3, arn


def args_for(secret_arn, port=PG_PORT, **extra):
    argv = [
        "pg_extractor.py",
        "--jdbc_url",
        f"jdbc:postgresql://{PG_HOST}:{port}/{DB}",
        "--secret_id",
        secret_arn,
        "--output_path_base",
        BASE,
        "--ssl_mode",
        "require",
    ]
    for key, value in extra.items():
        argv += [f"--{key}", value]
    return argv


def list_keys(s3, folder):
    return sorted(
        o["Key"]
        for o in s3.list_objects_v2(Bucket=BUCKET, Prefix=f"raw/app/{folder}/").get("Contents", [])
    )


def read_table(s3, folder):
    keys = list_keys(s3, folder)
    bodies = [s3.get_object(Bucket=BUCKET, Key=k)["Body"].read() for k in keys]
    tables = [pq.read_table(io.BytesIO(body)) for body in bodies]
    return keys, tables


def test_discover_dumps_typed_parquet_and_skips_denied(aws, capsys):
    s3, arn = aws
    pg_extractor.main(args_for(arn, discover="true", fetchsize="2"))
    out = capsys.readouterr().out

    keys, tables = read_table(s3, "orders")
    assert len(keys) == 3, "5 rows at fetchsize 2 -> 3 parts; the stale part is deleted"
    rows = sum(t.num_rows for t in tables)
    assert rows == 5
    schema = tables[0].schema
    assert str(schema.field("id").type) == "int64"
    assert str(schema.field("amount").type) == "decimal128(12, 2)"
    assert str(schema.field("ratio").type) == "string"  # unconstrained numeric
    assert str(schema.field("created_at").type) == "timestamp[us, tz=UTC]"
    assert str(schema.field("local_at").type) == "timestamp[us]"
    assert str(schema.field("day").type) == "date32[day]"
    first = tables[0].to_pylist()[0]
    assert first["amount"] == Decimal("1.50")
    assert json.loads(first["tags"]) == ["a", "b"]
    assert json.loads(first["meta"]) == {"n": 1}
    assert first["ref"] == "00000000-0000-0000-0000-000000000001"

    keys, tables = read_table(s3, "empty_table")
    assert len(keys) == 1 and tables[0].num_rows == 0
    assert tables[0].schema.names == ["id", "name"]

    assert read_table(s3, "mixed_case")[1][0].num_rows == 1
    assert list_keys(s3, "schema_migrations") == [], "bookkeeping tables are never discovered"
    assert list_keys(s3, "billing_invoices") == [], "discover scans one schema"
    assert "DENIED  public.secret_stuff" in out


def test_tables_mode_fails_at_the_end_but_writes_the_rest(aws):
    s3, arn = aws
    with pytest.raises(RuntimeError, match="public.secret_stuff"):
        pg_extractor.main(args_for(arn, tables=json.dumps(["secret_stuff", "billing.invoices"])))
    assert read_table(s3, "billing_invoices")[1][0].num_rows == 2


def test_permission_denied_does_not_delete_existing_data(aws):
    s3, arn = aws
    s3.put_object(Bucket=BUCKET, Key="raw/app/secret_stuff/keep.parquet", Body=b"x")
    pg_extractor.main(args_for(arn, discover="true"))
    assert list_keys(s3, "secret_stuff") == ["raw/app/secret_stuff/keep.parquet"]


def test_failed_table_keeps_previous_snapshot(aws, monkeypatch):
    s3, arn = aws
    real_write_part = pg_extractor.write_part

    def flaky_write_part(ctx, table, bucket, prefix, index):
        if index == 1:
            raise OSError("S3 went away")
        return real_write_part(ctx, table, bucket, prefix, index)

    monkeypatch.setattr(pg_extractor, "write_part", flaky_write_part)
    with pytest.raises(RuntimeError, match="public.orders"):
        pg_extractor.main(args_for(arn, tables='["orders"]', fetchsize="2"))
    assert list_keys(s3, "orders") == ["raw/app/orders/part-old.snappy.parquet"], (
        "the old snapshot stays and the new part 0 is removed"
    )


def test_full_dump_swaps_only_after_the_last_part(aws, monkeypatch):
    s3, arn = aws
    seen = []
    real_write_part = pg_extractor.write_part

    def spy(ctx, table, bucket, prefix, index):
        seen.append(list_keys(s3, "orders"))
        return real_write_part(ctx, table, bucket, prefix, index)

    monkeypatch.setattr(pg_extractor, "write_part", spy)
    pg_extractor.main(args_for(arn, tables='["orders"]', fetchsize="2"))
    assert all("raw/app/orders/part-old.snappy.parquet" in keys for keys in seen)
    keys = list_keys(s3, "orders")
    assert len(keys) == 3 and "raw/app/orders/part-old.snappy.parquet" not in keys


def test_incremental_appends_only_new_rows(aws):
    s3, arn = aws
    s3.put_object(Bucket=BUCKET, Key="raw/app/events/legacy-flat.parquet", Body=b"x")
    argv = args_for(
        arn,
        tables='["events"]',
        incremental='{"public.events": "updated_at"}',
        state_path=f"s3://{BUCKET}/state/app/",
    )

    # First run: full reload into today's partition, replacing the flat layout.
    pg_extractor.main(argv)
    first = list_keys(s3, "events")
    assert len(first) == 1 and "/ingest_date=" in first[0]
    assert (
        pq.read_table(
            io.BytesIO(s3.get_object(Bucket=BUCKET, Key=first[0])["Body"].read())
        ).num_rows
        == 4
    )
    state = json.loads(s3.get_object(Bucket=BUCKET, Key="state/app/events.json")["Body"].read())
    assert state["column"] == "updated_at" and state["value"].startswith("2026-01-01T00:03:00")

    conn = admin_conn(DB)
    conn.cursor().execute(
        "INSERT INTO events VALUES (4, '2026-01-02 00:00:00+00'), (5, '2026-01-02 00:00:01+00')"
    )
    conn.close()

    # Second run: only the two new rows, appended next to the first part.
    pg_extractor.main(argv)
    keys = list_keys(s3, "events")
    new = [k for k in keys if k not in first]
    assert first[0] in keys and len(new) == 1
    rows = pq.read_table(io.BytesIO(s3.get_object(Bucket=BUCKET, Key=new[0])["Body"].read()))
    assert sorted(rows.column("id").to_pylist()) == [4, 5]

    # Third run: nothing new, nothing written, watermark unchanged.
    pg_extractor.main(argv)
    assert list_keys(s3, "events") == keys
    state = json.loads(s3.get_object(Bucket=BUCKET, Key="state/app/events.json")["Body"].read())
    assert state["value"].startswith("2026-01-02T00:00:01")


def test_incremental_needs_state_path(aws):
    _, arn = aws
    with pytest.raises(ValueError, match="state_path"):
        pg_extractor.main(
            args_for(arn, tables='["events"]', incremental='{"events": "updated_at"}')
        )


def test_objects_are_kms_encrypted(aws):
    s3, arn = aws
    key_arn = boto3.client("kms").create_key()["KeyMetadata"]["Arn"]
    pg_extractor.main(args_for(arn, tables='["orders"]', s3_kms_key_arn=key_arn))
    for key in list_keys(s3, "orders"):
        head = s3.head_object(Bucket=BUCKET, Key=key)
        assert head["ServerSideEncryption"] == "aws:kms" and head["SSEKMSKeyId"].endswith(
            key_arn.split("/")[-1]
        )


def test_credentials_never_come_from_arguments(aws):
    _, arn = aws
    args = pg_extractor.parse_args(args_for(arn, tables='["orders"]') + ["--password", "x"])
    assert "password" not in args


@pytest.mark.skipif("PG_NOSSL_PORT" not in os.environ, reason="needs a server without TLS")
def test_refuses_plaintext_fallback(aws):
    _, arn = aws
    with pytest.raises(Exception, match="(?i)ssl"):
        argv = args_for(arn, port=int(os.environ["PG_NOSSL_PORT"]))
        pg_extractor.connect(pg_extractor.parse_args(argv))


@pytest.mark.parametrize(
    "url, expected",
    [
        ("jdbc:postgresql://db.example.com/app", ("db.example.com", 5432, "app")),
        ("jdbc:postgresql://db:6543/app?sslmode=require", ("db", 6543, "app")),
    ],
)
def test_parse_jdbc_url(url, expected):
    assert pg_extractor.parse_jdbc_url(url) == expected


def test_folder_names():
    assert pg_extractor.folder_name("public", "Orders") == "orders"
    assert pg_extractor.folder_name("billing", "invoices") == "billing_invoices"
    assert pg_extractor.folder_name("public", "Mixed Case") == "mixed_case"
