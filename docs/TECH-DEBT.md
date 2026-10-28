# Technical debt

Known gaps, with the file and line they live in. Tick or update an item in the
same PR that touches it; add new ones here.

- [x] **Non-atomic overwrite** — fixed in 0.3.0: write-then-delete in
  `scripts/pg_extractor.py` (`extract_table`). Remaining: a query that runs
  during the delete calls can see old and new rows together. Action if that
  matters: write Iceberg tables instead of plain Parquet.
- [x] **No Glue security configuration** — fixed in 0.3.0
  (`create_security_configuration`, `security_configuration`, `kms_key_arn`).
- [x] **Full dumps only** — fixed in 0.3.0 (`extract_incremental`).
  Remaining: no deletes or upserts (rows are appended as new versions), and
  late commits with a lower watermark are missed. Action if needed: logical
  replication / DMS CDC into Iceberg.
- [x] **Release automation** — release-please since 0.4.0
  (`.github/workflows/release-please.yml`), with PR titles checked as
  Conventional Commits.
- [x] **Not on the Terraform Registry** — published as
  `IngMatrix-PGB/glue-jdbc-ingestion/aws` on 2026-10-28; new tags appear
  through the GitHub webhook.
- [ ] **Registry publishing uses the legacy GitHub sign-in** — HashiCorp is
  deprecating it in favour of HCP Terraform public namespaces. Action: move
  the module to an HCP Terraform organization before the legacy sign-in is
  removed.
- [x] **No LICENSE** — Apache-2.0.
- [ ] **No apply in a real AWS account** — CI applies the module to Floci
  (`tests/floci`), which accepts the Glue API but does not run the script or
  enforce IAM, KMS key policies or CloudWatch Logs encryption. Pending: one
  run in a sandbox account to confirm a Python shell job with a security
  configuration writes encrypted logs, and the grants submodule against
  RDS. Expected cost: cents (0.0625 DPU for a minute, a `db.t4g.micro`).
- [ ] **0.2.0 to 0.4.2 may fail to download for a few days** — on
  2026-10-28 the history was rewritten to remove a work email from the
  commits, which moved every tag. After "Resync Module" the Registry points
  at the new SHAs, but CloudFront can serve the old ones to Terraform
  (gzip requests) until its 7-day cache expires. 0.4.3 was released so
  `~> 0.4` resolves to a version that was never cached. Action: none; close
  this item after 2026-11-04.
