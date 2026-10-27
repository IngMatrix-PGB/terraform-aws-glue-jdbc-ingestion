# Complete example

- Several PostgreSQL sources from one `postgres_sources` map (`for_each`), each
  dumped by the bundled extractor on its own schedule.
- A catalog database and a chained crawler per source (`crawler_table_level = 4`
  for `s3://<lake>/raw/<source>/<table>/`).
- EventBridge alerts for failed jobs and crawlers to one SNS topic, with an
  optional email subscription.
- An optional MySQL source read with Spark (`glueetl`, FLEX) through the Glue
  connection, whose `SECRET_ID` supplies the credentials.

## Without internet access from the subnet

Put the pg8000 wheels in `./libs`; they are uploaded and passed with
`--extra-py-files`, and `python_modules` is left empty:

```bash
pip download pg8000==1.31.5 --only-binary=:all: --python-version 3.9 -d libs/
```

That brings `pg8000`, `scramp` and `asn1crypto`.

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The example uses local state. For real environments add an S3 backend.
