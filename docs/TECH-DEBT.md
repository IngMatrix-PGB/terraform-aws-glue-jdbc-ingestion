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
- [ ] **Release automation** — versions and `CHANGELOG.md` are maintained by
  hand. Action: release-please on merge to `main`, then publish to the
  Terraform Registry. Blocked on a repository setting: Actions cannot open
  pull requests (`can_approve_pull_request_reviews = false`, workflow
  permissions read-only); enable "Allow GitHub Actions to create and approve
  pull requests" first.
- [ ] **No LICENSE** — the repository is public without a license, so reuse is
  not formally allowed. Action: choose one (MIT or Apache-2.0).
