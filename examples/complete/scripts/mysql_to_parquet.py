"""MySQL -> Parquet with Spark, reading through the Glue connection.

The connection carries the JDBC URL and a SECRET_ID; Glue resolves the
credentials, so the script never sees them. Each table overwrites its folder
under --output_path_base.
"""

import json
import re
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

args = getResolvedOptions(sys.argv, ["JOB_NAME", "connection_name", "tables", "output_path_base"])

glue = GlueContext(SparkContext.getOrCreate())
job = Job(glue)
job.init(args["JOB_NAME"], args)

base = args["output_path_base"].rstrip("/") + "/"
for table in json.loads(args["tables"]):
    frame = glue.create_dynamic_frame.from_options(
        connection_type="mysql",
        connection_options={
            "useConnectionProperties": "true",
            "connectionName": args["connection_name"],
            "dbtable": table,
        },
    )
    folder = re.sub(r"[^a-z0-9_]", "_", table.lower())
    frame.toDF().write.mode("overwrite").parquet(f"{base}{folder}/")
    print(f"OK {table} -> {base}{folder}/")

job.commit()
