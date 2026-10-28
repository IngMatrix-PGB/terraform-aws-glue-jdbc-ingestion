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
- [ ] **Not on the Terraform Registry** — the repository already has the
  `terraform-aws-<name>` layout and `vX.Y.Z` tags. Action: publish it from
  registry.terraform.io with the owner's GitHub account.
- [x] **No LICENSE** — Apache-2.0.
