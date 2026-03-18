#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mysql_ansible_dir="$(cd "${script_dir}/.." && pwd)"
portable_ansible_home="${PORTABLE_ANSIBLE_HOME:-/usr/local/dbbot/portable-ansible-v0.5.0-py3}"

set +e
output="$(
  python3 "${portable_ansible_home}/ansible-playbook" \
    -i "localhost," \
    "${mysql_ansible_dir}/tests/validate_default_password_guard_hint.yml" \
    2>&1
)"
status=$?
set -e

if [ "${status}" -eq 0 ]; then
  echo "Expected the default password guard test to fail, but it succeeded." >&2
  exit 1
fi

printf '%s\n' "${output}" | grep -F "Detected dbbot public default password(s):"
printf '%s\n' "${output}" | grep -F "fcs_allow_dbbot_default_passwd"
printf '%s\n' "${output}" | grep -F "ansible-playbook backup_script_8.4.yml -e"
