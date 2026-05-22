#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dbbot_root="$(cd "${script_dir}/../.." && pwd)"

assert_almalinux9_package() {
  local version="$1"
  local expected_package="$2"
  local expected_rule="$3"
  local output

  output="$(
    "${dbbot_root}/bin/dbbotctl" support packages \
      --stack mysql \
      --version "${version}" \
      --os AlmaLinux9 \
      --arch mysql_single_node \
      --exact all \
      --full \
      --format json
  )"

  SUPPORT_OUTPUT="${output}" \
  EXPECTED_VERSION="${version}" \
  EXPECTED_PACKAGE="${expected_package}" \
  EXPECTED_RULE="${expected_rule}" \
  python3 - <<'PY'
import json
import os
import sys

records = json.loads(os.environ["SUPPORT_OUTPUT"])
expected_version = os.environ["EXPECTED_VERSION"]
expected_package = os.environ["EXPECTED_PACKAGE"]
expected_rule = os.environ["EXPECTED_RULE"]

if len(records) != 1:
    print(f"expected one record for {expected_version}, got {len(records)}", file=sys.stderr)
    sys.exit(1)

record = records[0]
checks = {
    "version": expected_version,
    "os_type": "AlmaLinux9",
    "support_rule_os_type": expected_rule,
    "primary_package": expected_package,
    "status": "supported",
}

for key, expected_value in checks.items():
    actual_value = record.get(key)
    if actual_value != expected_value:
        print(
            f"{expected_version}: expected {key}={expected_value!r}, got {actual_value!r}",
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

assert_almalinux9_package \
  "5.7.44" \
  "mysql-5.7.44-linux-glibc2.12-x86_64.tar.gz" \
  "all"

assert_almalinux9_package \
  "8.0.44" \
  "mysql-8.0.44-linux-glibc2.28-x86_64.tar.xz" \
  "rhel9-family"

assert_almalinux9_package \
  "8.4.9" \
  "mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz" \
  "rhel9-family"

assert_almalinux9_package \
  "9.7.0" \
  "mysql-9.7.0-linux-glibc2.28-x86_64-minimal.tar.xz" \
  "not-rhel7-family"
