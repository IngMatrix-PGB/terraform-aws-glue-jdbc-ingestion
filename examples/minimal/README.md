# Minimal example

One PostgreSQL database dumped to Parquet every 30 minutes with the bundled
extractor in discover mode (every table of `public`).

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
aws glue start-job-run --job-name "$(terraform output -raw job_name)"
```

Prerequisites: the secret (`{"username": "...", "password": "..."}`), a private
subnet that reaches the database, S3 (gateway endpoint), Secrets Manager
(interface endpoint or NAT) and PyPI (NAT, for `pg8000`), and a security group
with a self-referencing all-TCP rule.

The example uses local state. For real environments add an S3 backend.
