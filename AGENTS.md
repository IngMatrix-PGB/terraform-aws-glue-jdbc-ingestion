# AGENTS.md

Instructions for coding agents and people working on this module.

## Layout

- Root: the module (`main.tf` job and connection, `crawler.tf`, `iam.tf`,
  `alerts.tf`). Keep resource addresses stable; if one must change, add a
  `moved` block and a CHANGELOG entry.
- `scripts/pg_extractor.py`: bundled extractor. Must stay Python 3.9
  compatible (Glue Python shell runtime).
- `examples/`: runnable roots with an exact provider pin.
- `tests/*.tftest.hcl`: plan-only tests with a mocked provider.
  `tests/python/`: extractor integration tests (PostgreSQL + moto).

## Commands

```bash
terraform fmt -recursive && terraform validate
terraform test
tflint --recursive --config "$(pwd)/.tflint.hcl"
checkov -d . --config-file .checkov.yaml
terraform-docs .                      # regenerates the README inputs table
ruff check . && ruff format --check .
PG_PORT=55432 AWS_DEFAULT_REGION=us-east-1 pytest tests/python
```

## Rules

- Never accept credentials as variables, job arguments or connection
  properties: only a secret reference.
- New inputs need a description, a type, a validation when the value space is
  closed, and a test in `tests/`.
- Behaviour changes go in `CHANGELOG.md`; known gaps in `docs/TECH-DEBT.md`.
- No organization-specific names, account IDs or endpoints: this repository is public.
