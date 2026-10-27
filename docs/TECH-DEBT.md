# Technical debt

Known gaps, with the file and line they live in. Tick or update an item in the
same PR that touches it; add new ones here.

- [ ] **Non-atomic overwrite** — `scripts/pg_extractor.py` (`extract_table`)
  deletes a table's folder before writing the new parts, so readers can see an
  empty or partial table for a few seconds. Action: write to a staging prefix
  and swap (or write a manifest that readers follow).
- [ ] **No Glue security configuration** — `aws_glue_job.this` and
  `aws_glue_crawler.this` run without KMS encryption for S3 output, CloudWatch
  logs and bookmarks (Checkov CKV_AWS_195, skipped in `.checkov.yaml`).
  Action: optional `aws_glue_security_configuration` with a KMS key input.
- [ ] **Full dumps only** — the extractor rewrites every table on each run.
  Action: optional incremental mode (watermark column per table, append to
  date partitions).
- [ ] **Release automation** — versions and `CHANGELOG.md` are maintained by
  hand. Action: release-please (or semantic-release) on merge to `main`, then
  publish to the Terraform Registry.
- [ ] **No LICENSE** — the repository is public without a license, so reuse is
  not formally allowed. Action: choose one (MIT or Apache-2.0).
