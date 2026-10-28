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
  --incremental       JSON object {"schema.table": "watermark_column"}; those
                      tables are appended instead of overwritten
  --state_path        s3://bucket/prefix/ for watermarks (needed by
                      --incremental)
  --s3_kms_key_arn    KMS key for SSE-KMS on every object the job writes

Behaviour:
  * Credentials only from Secrets Manager; never from arguments.
  * Read-only session; each table is read with a server-side cursor in chunks,
    so memory stays flat regardless of table size.
  * Full dumps replace a table's folder write-then-delete: the new parts are
    written next to the old ones (file names carry the run id) and the old
    objects are deleted only after the last part is written. A failed table
    keeps its previous snapshot and its new parts are removed, so readers
    never see an empty or partial table; they can see old and new rows
    together for the duration of the delete calls. Two concurrent runs on one
    prefix still race (keep max_concurrent_runs = 1).
  * Incremental tables are appended to <table>/ingest_date=YYYY-MM-DD/ with
    the rows whose watermark column is greater than the last value stored in
    --state_path. The first run (no state, or a different column) is a full
    reload that replaces the folder. Delivery is at-least-once: if the job
    dies after writing parts and before saving the watermark, the next run
    writes those rows again. Rows are new versions, not upserts: deduplicate
    by primary key downstream. Rows whose watermark is NULL are only read by
    the first run, and a transaction that commits a value lower than one
    already read is missed, so prefer a column assigned at commit time (or
    a sequence) and schedule a periodic full reload if that matters.
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
from dataclasses import dataclass, field
from datetime import date, datetime, timezone

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
    "incremental",
    "state_path",
    "s3_kms_key_arn",
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

# Watermark columns must have a total order that survives a round trip
# through text (the stored value is cast back to the column type).
WATERMARK_TYPES = {
    "smallint",
    "integer",
    "bigint",
    "numeric",
    "date",
    "timestamp without time zone",
    "timestamp with time zone",
}


@dataclass
class Context:
    s3: object
    fetchsize: int = DEFAULT_FETCHSIZE
    run_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    ingest_date: str = field(default_factory=lambda: datetime.now(timezone.utc).date().isoformat())
    kms_key_arn: str = None
    state_path: str = None

    def put(self, bucket, key, body, content_type=None):
        extra = {"ContentType": content_type} if content_type else {}
        if self.kms_key_arn:
            extra.update(ServerSideEncryption="aws:kms", SSEKMSKeyId=self.kms_key_arn)
        self.s3.put_object(Bucket=bucket, Key=key, Body=body, **extra)


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
    """[(name, data_type, arrow type, converter)] in ordinal order."""
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
    return [(name, dt, *arrow_column(dt, p, s)) for name, dt, p, s in rows]


def to_arrow(rows, columns):
    arrays, fields = [], []
    for idx, (name, _, arrow_type, convert) in enumerate(columns):
        arrays.append(pa.array([convert(r[idx]) for r in rows], type=arrow_type))
        fields.append(pa.field(name, arrow_type))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
def delete_keys(s3, bucket, keys):
    keys = list(keys)
    for i in range(0, len(keys), 1000):
        objects = [{"Key": k} for k in keys[i : i + 1000]]
        s3.delete_objects(Bucket=bucket, Delete={"Objects": objects, "Quiet": True})


def delete_prefix(s3, bucket, prefix, keep=()):
    """Delete every object under prefix except the keys in keep."""
    keep = set(keep)
    stale = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        stale += [o["Key"] for o in page.get("Contents", []) if o["Key"] not in keep]
    delete_keys(s3, bucket, stale)


def write_part(ctx, table, bucket, prefix, index):
    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    key = f"{prefix}part-{ctx.run_id}-{index:05d}.snappy.parquet"
    ctx.put(bucket, key, buf.getvalue())
    return key


# ---------------------------------------------------------------------------
# Watermarks
# ---------------------------------------------------------------------------
def state_location(ctx, schema, table):
    bucket, prefix = parse_s3_uri(ctx.state_path.rstrip("/") + "/")
    return bucket, f"{prefix}{folder_name(schema, table)}.json"


def read_state(ctx, schema, table):
    bucket, key = state_location(ctx, schema, table)
    try:
        body = ctx.s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except ctx.s3.exceptions.NoSuchKey:
        return None
    return json.loads(body)


def write_state(ctx, schema, table, state):
    bucket, key = state_location(ctx, schema, table)
    ctx.put(bucket, key, json.dumps(state, indent=2).encode(), "application/json")


def watermark_text(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    return str(value)


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


def extract_table(conn, ctx, schema, table, out_uri, watermark_column=None):
    """Dump one table to out_uri. Returns (rows, mode)."""
    bucket, prefix = parse_s3_uri(out_uri)
    state = read_state(ctx, schema, table) if watermark_column else None
    if state and (state.get("column") != watermark_column or state.get("value") is None):
        state = None  # new column or nothing read yet: reload
    delta = state is not None
    if delta and state.get("type") not in WATERMARK_TYPES:
        raise ValueError(f"Corrupt watermark state for {schema}.{table}: {state}")

    query = f"SELECT * FROM {qident(schema)}.{qident(table)}"
    params = ()
    if delta:
        # The type comes from our own state file and is checked against
        # WATERMARK_TYPES above, so it is safe to inline.
        query += f" WHERE {qident(watermark_column)} > CAST(%s AS {state['type']})"
        params = (state["value"],)
    part_prefix = f"{prefix}ingest_date={ctx.ingest_date}/" if watermark_column else prefix

    cursor_name = f"pgx_{uuid.uuid4().hex[:12]}"
    cur = conn.cursor()
    written, total, high = [], 0, None
    try:
        # Server-side cursor: rows arrive in fetchsize chunks, one Parquet
        # part each. DECLARE goes first: it raises "permission denied" before
        # anything is written, and information_schema hides columns of
        # unreadable tables.
        cur.execute(f"DECLARE {cursor_name} NO SCROLL CURSOR FOR {query}", params)
        columns = table_columns(conn, schema, table)
        wm_index = None
        if watermark_column:
            names = [c[0] for c in columns]
            if watermark_column not in names:
                raise LookupError(f"Watermark column {watermark_column} not in {schema}.{table}")
            wm_index = names.index(watermark_column)
            wm_type = columns[wm_index][1]
            if wm_type not in WATERMARK_TYPES:
                raise TypeError(f"Watermark {watermark_column} has unsupported type {wm_type}")

        while True:
            cur.execute(f"FETCH FORWARD {int(ctx.fetchsize)} FROM {cursor_name}")
            rows = cur.fetchall()
            # A full dump of an empty table still gets one empty part, so the
            # crawler sees its columns; an empty delta writes nothing.
            if rows or (not written and not delta):
                part = to_arrow(rows, columns)
                written.append(write_part(ctx, part, bucket, part_prefix, len(written)))
            total += len(rows)
            if wm_index is not None:
                values = [r[wm_index] for r in rows if r[wm_index] is not None]
                if values:
                    high = max(values) if high is None else max(high, *values)
            if len(rows) < ctx.fetchsize:
                break
    except Exception:
        # Leave the previous snapshot as it was.
        delete_keys(ctx.s3, bucket, written)
        raise
    finally:
        cur.close()
        conn.rollback()  # read-only transaction: ends it and closes the cursor

    if not delta:
        # Swap: the new parts are complete, now drop everything else.
        delete_prefix(ctx.s3, bucket, prefix, keep=written)
    if watermark_column:
        value = watermark_text(high) if high is not None else (state or {}).get("value")
        write_state(
            ctx,
            schema,
            table,
            {
                "column": watermark_column,
                "type": wm_type,
                "value": value,
                "run_id": ctx.run_id,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
        )
    return total, ("delta" if delta else "full")


def is_permission_denied(exc):
    err = exc.args[0] if exc.args else None
    if isinstance(err, dict):
        return err.get("C") == INSUFFICIENT_PRIVILEGE
    return "permission denied" in str(exc).lower()


def run(args, conn, s3):
    discover = args.get("discover", "false").lower() == "true"
    base = args["output_path_base"].rstrip("/") + "/"
    ctx = Context(
        s3=s3,
        fetchsize=int(args.get("fetchsize", DEFAULT_FETCHSIZE)),
        kms_key_arn=args.get("s3_kms_key_arn") or None,
        state_path=args.get("state_path") or None,
    )
    incremental = {split_table(t): c for t, c in json.loads(args.get("incremental", "{}")).items()}
    if incremental and not ctx.state_path:
        raise ValueError("--incremental needs --state_path")

    if discover:
        work = discover_tables(
            conn, args.get("schema", "public"), json.loads(args.get("exclude_tables", "[]"))
        )
    else:
        work = [split_table(t) for t in json.loads(args.get("tables", "[]"))]
    if not work:
        raise ValueError("Nothing to extract: pass --tables or --discover true")
    missing = sorted(f"{s}.{t}" for s, t in set(incremental) - set(work))
    if missing:
        print(f"WARNING: incremental tables not extracted this run: {', '.join(missing)}")
    print(f"{len(work)} table(s) to extract into {base} (run {ctx.run_id})")

    failed, denied = [], []
    for schema, table in work:
        out_uri = f"{base}{folder_name(schema, table)}/"
        try:
            rows, mode = extract_table(
                conn, ctx, schema, table, out_uri, incremental.get((schema, table))
            )
            print(f"  OK      {schema}.{table} -> {out_uri} ({rows} rows, {mode})")
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
