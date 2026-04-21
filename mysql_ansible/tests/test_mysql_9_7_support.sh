#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mysql_ansible_dir="$(cd "${script_dir}/.." && pwd)"
portable_ansible_home="${PORTABLE_ANSIBLE_HOME:-/usr/local/dbbot/portable-ansible}"
template_path="${mysql_ansible_dir}/roles/mysql_server/templates/9.7/my.cnf.j2"

python3 "${portable_ansible_home}/ansible-playbook" \
  -i "localhost," \
  "${mysql_ansible_dir}/tests/validate_mysql_9_7_package_defaults.yml"

grep -F "binlog_transaction_dependency_history_size = 1000000" "${template_path}"

if grep -Fq "replica_parallel_type" "${template_path}"; then
  echo "replica_parallel_type should not appear in the MySQL 9.7 template." >&2
  exit 1
fi

if grep -Fq "group_replication_allow_local_lower_version_join" "${template_path}"; then
  echo "group_replication_allow_local_lower_version_join should not appear in the MySQL 9.7 template." >&2
  exit 1
fi

if grep -Fq "innodb_log_writer_threads" "${template_path}"; then
  echo "innodb_log_writer_threads should not be set in the MySQL 9.7 template." >&2
  exit 1
fi
