import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext

# Minimal JDBC extract skeleton (PostgreSQL). Connection uses Glue Connection; override with job args if needed.
args = getResolvedOptions(sys.argv, ["JOB_NAME"])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

print(f"Starting job: {args['JOB_NAME']}")

# Example: read via Glue Connection (credentials from connection_properties)
# df = spark.read.format("jdbc")\
#     .option("url", "jdbc:postgresql://host:5432/db")\
#     .option("dbtable", "public.sample_table")\
#     .option("user", "...")\
#     .option("password", "...")\
#     .load()
# df.show(5)

print("Done.")
