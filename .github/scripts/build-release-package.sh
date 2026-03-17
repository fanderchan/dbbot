#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <tag> <output-dir>" >&2
  exit 1
fi

tag="$1"
output_dir="$2"
package_name="dbbot-${tag}.tar.gz"
package_root="dbbot"
package_path="${output_dir}/${package_name}"

mkdir -p "$output_dir"

file_list="$(mktemp)"
dir_list="$(mktemp)"
cleanup() {
  rm -f "$file_list"
  rm -f "$dir_list"
}
trap cleanup EXIT

readonly ROOT_FILES=(
  "LICENSE"
  "NOTICE"
  "README.en.md"
  "README.md"
  "THIRD_PARTY_LICENSES.txt"
  "VERSION"
)

readonly ALLOWED_PREFIXES=(
  "clickhouse_ansible/inventory/"
  "clickhouse_ansible/playbooks/"
  "clickhouse_ansible/roles/"
  "monitoring_prometheus_ansible/inventory/"
  "monitoring_prometheus_ansible/playbooks/"
  "monitoring_prometheus_ansible/roles/"
  "mysql_ansible/inventory/"
  "mysql_ansible/playbooks/"
  "mysql_ansible/roles/"
  "portable-ansible-v0.5.0-py3/"
)

readonly EMPTY_DIRS=(
  "clickhouse_ansible/downloads"
  "monitoring_prometheus_ansible/downloads"
  "mysql_ansible/downloads"
  "mysql_ansible/playbooks/logs"
)

is_root_file() {
  local path="$1"
  local item

  for item in "${ROOT_FILES[@]}"; do
    if [[ "$path" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

is_under_allowed_prefix() {
  local path="$1"
  local prefix

  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "$path" == "$prefix"* ]]; then
      return 0
    fi
  done
  return 1
}

is_placeholder_file() {
  local path="$1"
  local base

  base="$(basename "$path")"
  case "$base" in
    .gitkeep|.keep|.gitignore|.git_keep)
      return 0
      ;;
  esac
  return 1
}

is_hidden_path() {
  local path="$1"

  [[ "/$path" =~ /(\.[^/]+)($|/) ]]
}

append_dir() {
  local dir="$1"

  if [[ -n "$dir" ]]; then
    printf '%s\0' "$dir" >> "$dir_list"
  fi
}

while IFS= read -r -d '' path; do
  if is_root_file "$path"; then
    printf '%s\0' "$path" >> "$file_list"
    continue
  fi

  if ! is_under_allowed_prefix "$path"; then
    continue
  fi

  if is_placeholder_file "$path"; then
    append_dir "$(dirname "$path")"
    continue
  fi

  if is_hidden_path "$path"; then
    continue
  fi

  printf '%s\0' "$path" >> "$file_list"
done < <(git ls-files -z)

for dir in "${EMPTY_DIRS[@]}"; do
  append_dir "$dir"
done

sort -zu "$file_list" -o "$file_list"
sort -zu "$dir_list" -o "$dir_list"

cat "$dir_list" >> "$file_list"

tar \
  --no-recursion \
  --null \
  --files-from="$file_list" \
  --sort=name \
  --transform="s#^#${package_root}/#" \
  -czf "$package_path"

printf '%s\n' "$package_path"
