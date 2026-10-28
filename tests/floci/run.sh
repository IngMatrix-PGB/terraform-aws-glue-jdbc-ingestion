#!/usr/bin/env bash
# Apply / no-op plan / inspect / destroy against Floci (https://floci.io), a
# local AWS emulator. It checks that a first apply works when every
# dependency is created in the same run, that a second plan is empty, and
# that the job and crawler carry the security configuration. Floci accepts
# the Glue API but does not run the script or enforce IAM or KMS, so this is
# not a substitute for an apply in a real account.
#   docker run -d -p 4566:4566 floci/floci:2.3.0 && tests/floci/run.sh
set -euo pipefail
cd "$(dirname "$0")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL="${FLOCI_ENDPOINT:-http://localhost:4566}"
unset AWS_PROFILE
tf() { terraform "$@" -input=false -no-color -var "endpoint=$AWS_ENDPOINT_URL"; }

terraform init -input=false -no-color >/dev/null
trap 'tf destroy -auto-approve >/dev/null' EXIT
tf apply -auto-approve >/dev/null
echo "ok   first apply with every dependency created in the same run"

set +e
tf plan -detailed-exitcode >/dev/null
rc=$?
set -e
if [ "$rc" != 0 ]; then
  echo "FAIL: second plan is not empty (exit $rc)" >&2
  exit 1
fi
echo "ok   second plan has no changes"

job=$(aws glue get-job --job-name orders-e2e --output json)
crawler=$(aws glue get-crawler --name orders-e2e --output json)
python3 - "$job" "$crawler" <<'PY'
import json, sys
job = json.loads(sys.argv[1])["Job"]
crawler = json.loads(sys.argv[2])["Crawler"]
args = job["DefaultArguments"]
checks = {
    "job is Python shell 3.9": job["Command"]["Name"] == "pythonshell" and job["Command"]["PythonVersion"] == "3.9",
    "job has the security configuration": job.get("SecurityConfiguration") == "orders-e2e",
    "crawler has the security configuration": crawler.get("CrawlerSecurityConfiguration") == "orders-e2e",
    "extractor encrypts with the KMS key": args.get("--s3_kms_key_arn", "").startswith("arn:aws:kms:"),
    "incremental state path is set": args.get("--state_path", "").endswith("/orders-e2e/state/"),
    "no password in job arguments": not any("password" in k.lower() for k in args),
}
for name, ok in checks.items():
    print(("ok   " if ok else "FAIL ") + name)
sys.exit(0 if all(checks.values()) else 1)
PY
