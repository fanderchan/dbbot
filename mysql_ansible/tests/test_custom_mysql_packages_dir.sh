#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mysql_ansible_dir="$(cd "${script_dir}/.." && pwd)"
portable_ansible_home="${PORTABLE_ANSIBLE_HOME:-/usr/local/dbbot/portable-ansible-v0.5.0-py3}"
package_name="mysql-8.4.8-linux-glibc2.17-x86_64-minimal.tar.xz"
temp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

touch "${temp_dir}/${package_name}"

MYSQL_PACKAGES_DIR_TEST="${temp_dir}" \
MYSQL_PACKAGE_TEST="${package_name}" \
python3 "${portable_ansible_home}/ansible-playbook" \
  -i "localhost," \
  "${mysql_ansible_dir}/tests/check_if_packages_exist_custom_dir.yml"
