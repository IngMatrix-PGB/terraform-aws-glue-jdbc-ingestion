"""PostgreSQL -> Parquet (S3) extractor for AWS Glue Python shell jobs.

Bundled with the terraform-aws-glue-jdbc-ingestion module. Runs on Glue
Python shell 3.9 with `--library-set analytics` (pyarrow, boto3) plus pg8000,
a pure-Python driver with native SCRAM-SHA-256 support (the psycopg2 shipped
with the runtime links an old libpq that cannot authenticate against
SCRAM-only servers such as current RDS defaults).

Arguments (the module sets them):
  --jdbc_url          jdbc:postgresql://host[:port]/database
  --secret_id         Secrets Manager secret with username/password. Without a
                      password the job uses RDS IAM authentication.
  --output_path_base  s3://bucket/prefix/  (one sub-folder per table)
  --tables            JSON list of "schema.table" (schema defaults to public)
  --discover          "true" to dump every base table of --schema instead
  --schema            schema scanned in discover mode (default public)
  --exclude_tables    JSON list of tables to skip in discover mode
  --fetchsize         rows per chunk / Parquet part (default 50000)
  --ssl_mode          require | verify-full (no plaintext fallback)
  --ssl_root_cert     s3:// URI of a CA bundle, for verify-full

Behaviour:
  * Credentials only from Secrets Manager; never from arguments.
  * Read-only session; each table is read with a server-side cursor in chunks,
    so memory stays flat regardless of table size.
  * Each table's folder is overwritten: old objects are deleted, then new parts
    are written. Readers can see an empty or partial table for a few seconds,
    and two concurrent runs on one prefix duplicate rows (keep
    max_concurrent_runs = 1).
  * A failing table does not stop the others: the job fails at the end and
    lists them. In discover mode, tables without SELECT (SQLSTATE 42501) are
    skipped and reported instead; they are new tables nobody granted yet.
"""

import io
import json
import re
import ssl
import sys
import uuid
from datetime import timezone

import boto3
import pg8000.dbapi
import pyarrow as pa
import pyarrow.parquet as pq

REQUIRED_ARGS = ["jdbc_url", "secret_id", "output_path_base"]
OPTIONAL_ARGS = [
    "tables",
    "discover",
    "schema",
    "exclude_tables",
    "fetchsize",
    "ssl_mode",
    "ssl_root_cert",
]

# Migration bookkeeping and extension catalogs: not business data, and many
# databases share the same names, so dumping them into a shared output prefix
# would make jobs overwrite each other's folders.
ALWAYS_EXCLUDED = {
    "schema_migrations",
    "_prisma_migrations",
    "flyway_schema_history",
    "databasechangelog",
    "databasechangeloglock",
    "spatial_ref_sys",
}

DEFAULT_FETCHSIZE = 50000
INSUFFICIENT_PRIVILEGE = "42501"


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
def parse_args(argv):
    """Glue's getResolvedOptions, restricted to the optional args present."""
    present = [a for a in OPTIONAL_ARGS if f"--{a}" in argv]
    try:
        from awsglue.utils import getResolvedOptions
    except ImportError:  # local runs and tests
        import argparse

        parser = argparse.ArgumentParser()
        for name in REQUIRED_ARGS + present:
            parser.add_argument(f"--{name}", required=True)
        known, _ = parser.parse_known_args(argv[1:])
        return vars(known)
    return getResolvedOptions(argv, REQUIRED_ARGS + present)


def parse_jdbc_url(url):
    m = re.match(r"^jdbc:postgresql://([^:/?]+)(?::(\d+))?/([^?]+)", url)
    if not m:
        raise ValueError(f"Unsupported jdbc_url (expected jdbc:postgresql://host[:port]/db): {url}")
    return m.group(1), int(m.group(2) or 5432), m.group(3)


def parse_s3_uri(uri):
    m = re.match(r"^s3://([^/]+)/?(.*)$", uri)
    if not m:
        raise ValueError(f"Not an s3:// URI: {uri}")
    return m.group(1), m.group(2)


def split_table(name, default_schema="public"):
    """'schema.table' -> (schema, table); quotes are stripped."""
    parts = [p.strip().strip('"') for p in name.split(".")]
    if len(parts) == 1:
        return default_schema, parts[0]
    if len(parts) == 2:
        return parts[0], parts[1]
    raise ValueError(f"Invalid table name: {name}")


def folder_name(schema, table):
    base = table if schema == "public" else f"{schema}_{table}"
    return re.sub(r"[^a-z0-9_]", "_", base.lower())


def qident(identifier):
    return '"' + identifier.replace('"', '""') + '"'


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
def read_credentials(secret_id):
    secret = json.loads(
        boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)["SecretString"]
    )
    user = secret.get("username") or secret.get("user") or secret.get("db_user")
    password = secret.get("password") or secret.get("db_password")
    if not user:
        raise ValueError(f"Secret {secret_id} has no username")
    return user, password


def ssl_context(mode, root_cert_uri=None):
    if mode == "require":
        # Encrypted, server certificate not verified (libpq sslmode=require).
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if mode == "verify-full":
        if not root_cert_uri:
            raise ValueError("ssl_mode=verify-full needs --ssl_root_cert")
        bucket, key = parse_s3_uri(root_cert_uri)
        path = "/tmp/pg_extractor_root_ca.pem"
        boto3.client("s3").download_file(bucket, key, path)
        return ssl.create_default_context(cafile=path)
    raise ValueError(f"Unsupported ssl_mode: {mode}")


def connect(args):
    host, port, database = parse_jdbc_url(args["jdbc_url"])
    user, password = read_credentials(args["secret_id"])
    if not password:
        # RDS IAM auth: the token is only checked at login, so its 15 min
        # lifetime does not limit a long extraction on this one connection.
        rds = boto3.client("rds")
        password = rds.generate_db_auth_token(
            DBHostname=host, Port=port, DBUsername=user, Region=rds.meta.region_name
        )
    # An explicit SSLContext makes pg8000 raise "Server refuses SSL" instead
    # of continuing in plaintext.
    ctx = ssl_context(args.get("ssl_mode", "require"), args.get("ssl_root_cert"))
    # timeout is the socket deadline for every read, not just the login: high
    # enough for slow FETCHes, low enough to drop dead sockets. The job
    # timeout is the global backstop.
    conn = pg8000.dbapi.connect(
        host=host,
        port=port,
        database=database,
        user=user,
        password=password,
        ssl_context=ctx,
        timeout=300,
        application_name="glue-jdbc-ingestion",
    )
    cur = conn.cursor()
    cur.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
    cur.close()
    conn.commit()
    print(f"Connected to {database}@{host}:{port} as {user}")
    return conn


# ---------------------------------------------------------------------------
# Type mapping (information_schema.columns -> Arrow)
# ---------------------------------------------------------------------------
def _as_str(value):
    return None if value is None else str(value)


def _as_json(value):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return json.dumps(value, default=str)


def _as_utc(value):
    if value is None:
        return None
    return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)


def _identity(value):
    return value


def arrow_column(data_type, precision, scale):
    """(arrow type, converter) for a PostgreSQL column.

    Unconstrained numeric, arrays, json and anything unknown become strings:
    a fixed decimal scale would silently round, and nested types vary too much
    between rows to type them safely.
    """
    simple = {
        "boolean": (pa.bool_(), _identity),
        "smallint": (pa.int16(), _identity),
        "integer": (pa.int32(), _identity),
        "bigint": (pa.int64(), _identity),
        "real": (pa.float32(), _identity),
        "double precision": (pa.float64(), _identity),
        "date": (pa.date32(), _identity),
        "timestamp without time zone": (pa.timestamp("us"), _identity),
        "timestamp with time zone": (pa.timestamp("us", tz="UTC"), _as_utc),
        "time without time zone": (pa.time64("us"), _identity),
        "bytea": (pa.binary(), lambda v: None if v is None else bytes(v)),
        "json": (pa.string(), _as_json),
        "jsonb": (pa.string(), _as_json),
        "ARRAY": (pa.string(), _as_json),
    }
    if data_type in simple:
        return simple[data_type]
    if data_type == "numeric" and precision is not None and precision <= 38:
        return pa.decimal128(precision, scale or 0), _identity
    return pa.string(), _as_str


def table_columns(conn, schema, table):
    cur = conn.cursor()
    cur.execute(
        """
        SELECT column_name, data_type, numeric_precision, numeric_scale
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        ORDER BY ordinal_position
        """,
        (schema, table),
    )
    rows = cur.fetchall()
    cur.close()
    if not rows:
        raise LookupError(f"Table {schema}.{table} not found or not visible")
    return [(name, *arrow_column(dt, p, s)) for name, dt, p, s in rows]


def to_arrow(rows, columns):
    arrays, fields = [], []
    for idx, (name, arrow_type, convert) in enumerate(columns):
        arrays.append(pa.array([convert(r[idx]) for r in rows], type=arrow_type))
        fields.append(pa.field(name, arrow_type))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
def delete_prefix(s3, bucket, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        for i in range(0, len(keys), 1000):
            s3.delete_objects(Bucket=bucket, Delete={"Objects": keys[i : i + 1000], "Quiet": True})


def write_part(s3, table, bucket, prefix, index):
    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    key = f"{prefix}part-{index:05d}-{uuid.uuid4().hex[:8]}.snappy.parquet"
    s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue())


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------
def discover_tables(conn, schema, excluded):
    cur = conn.cursor()
    # pg_catalog, not information_schema: the latter hides tables the user
    # cannot read, and those must be reported, not silently missed.
    # relkind r = table, p = partitioned table (its partitions are skipped so
    # rows are not dumped twice).
    cur.execute(
        """
        SELECT c.relname
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind IN ('r', 'p') AND NOT c.relispartition
        ORDER BY c.relname
        """,
        (schema,),
    )
    names = [r[0] for r in cur.fetchall()]
    cur.close()
    skip = ALWAYS_EXCLUDED | set(excluded)
    return [(schema, n) for n in names if n not in skip]


def extract_table(conn, s3, schema, table, out_uri, fetchsize):
    """Dump one table to out_uri. Returns the row count."""
    bucket, prefix = parse_s3_uri(out_uri)
    cursor_name = f"pgx_{uuid.uuid4().hex[:12]}"
    cur = conn.cursor()
    # Server-side cursor: rows arrive in fetchsize chunks, one Parquet part
    # each. DECLARE goes first: it raises "permission denied" before anything
    # is deleted, and information_schema hides columns of unreadable tables.
    cur.execute(
        f"DECLARE {cursor_name} NO SCROLL CURSOR FOR SELECT * FROM {qident(schema)}.{qident(table)}"
    )
    columns = table_columns(conn, schema, table)
    delete_prefix(s3, bucket, prefix)
    total, part = 0, 0
    try:
        while True:
            cur.execute(f"FETCH FORWARD {int(fetchsize)} FROM {cursor_name}")
            rows = cur.fetchall()
            if not rows and part > 0:
                break
            # An empty table still gets one empty part, so the crawler sees
            # its columns.
            write_part(s3, to_arrow(rows, columns), bucket, prefix, part)
            total += len(rows)
            part += 1
            if len(rows) < fetchsize:
                break
    finally:
        cur.execute(f"CLOSE {cursor_name}")
        cur.close()
        conn.commit()
    return total


def is_permission_denied(exc):
    err = exc.args[0] if exc.args else None
    if isinstance(err, dict):
        return err.get("C") == INSUFFICIENT_PRIVILEGE
    return "permission denied" in str(exc).lower()


def run(args, conn, s3):
    discover = args.get("discover", "false").lower() == "true"
    fetchsize = int(args.get("fetchsize", DEFAULT_FETCHSIZE))
    base = args["output_path_base"].rstrip("/") + "/"

    if discover:
        work = discover_tables(
            conn, args.get("schema", "public"), json.loads(args.get("exclude_tables", "[]"))
        )
    else:
        work = [split_table(t) for t in json.loads(args.get("tables", "[]"))]
    if not work:
        raise ValueError("Nothing to extract: pass --tables or --discover true")
    print(f"{len(work)} table(s) to extract into {base}")

    failed, denied = [], []
    for schema, table in work:
        out_uri = f"{base}{folder_name(schema, table)}/"
        try:
            rows = extract_table(conn, s3, schema, table, out_uri, fetchsize)
            print(f"  OK      {schema}.{table} -> {out_uri} ({rows} rows)")
        except Exception as exc:  # keep going; fail at the end
            conn.rollback()
            if discover and is_permission_denied(exc):
                denied.append(f"{schema}.{table}")
                print(f"  DENIED  {schema}.{table} (no SELECT; skipped)")
                continue
            failed.append(f"{schema}.{table}")
            print(f"  ERROR   {schema}.{table}: {exc}")

    if denied:
        print(f"WARNING: {len(denied)} table(s) without SELECT were skipped: {', '.join(denied)}")
    if failed:
        raise RuntimeError(f"{len(failed)} table(s) failed: {', '.join(failed)}")
    print("Done.")
    return {"denied": denied, "failed": failed}


def main(argv):
    args = parse_args(argv)
    conn = connect(args)
    try:
        run(args, conn, boto3.client("s3"))
    finally:
        conn.close()


if __name__ == "__main__":
    main(sys.argv)
