#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <tag> <output-dir>" >&2
  exit 1
fi

tag="$1"
output_dir="$2"
package_name="dbbot-${tag}.tar.gz"
package_root="dbbot-${tag}"
package_path="${output_dir}/${package_name}"

mkdir -p "$output_dir"

file_list="$(mktemp)"
cleanup() {
  rm -f "$file_list"
}
trap cleanup EXIT

should_exclude() {
  local path="$1"

  if [[ "$path" == AGENTS.md ]]; then
    return 0
  fi

  if [[ "$path" == assets/* ]]; then
    return 0
  fi

  if [[ "$path" == clickhouse_ansible/examples/* ]]; then
    return 0
  fi

  if [[ "$path" == clickhouse_ansible/downloads/* ]]; then
    return 0
  fi

  if [[ "$path" == monitoring_prometheus_ansible/downloads/* ]]; then
    return 0
  fi

  if [[ "$path" == mysql_ansible/downloads/* ]]; then
    return 0
  fi

  if [[ "$path" == mysql_ansible/exporterregistrar/* ]]; then
    return 0
  fi

  if [[ "$path" == mysql_ansible/mysqlrouter_exporter/* ]]; then
    return 0
  fi

  if [[ "$path" == mysql_ansible/playbooks/logs/* ]]; then
    return 0
  fi

  if [[ "$path" == mysql_ansible/lint_all_yml_files.sh ]]; then
    return 0
  fi

  if [[ "$path" == monitoring_prometheus_ansible/lint_all_yml_files.sh ]]; then
    return 0
  fi

  if [[ "/$path" =~ /(\.[^/]+)($|/) ]]; then
    return 0
  fi

  return 1
}

while IFS= read -r -d '' path; do
  if should_exclude "$path"; then
    continue
  fi
  printf '%s\0' "$path" >> "$file_list"
done < <(git ls-files -z)

tar \
  --null \
  --files-from="$file_list" \
  --sort=name \
  --transform="s#^#${package_root}/#" \
  -czf "$package_path"

printf '%s\n' "$package_path"
