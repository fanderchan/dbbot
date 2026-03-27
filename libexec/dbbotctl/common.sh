#!/usr/bin/env bash

if [[ -n "${DBBOTCTL_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
readonly DBBOTCTL_COMMON_SH_LOADED=1

readonly DBBOT_STATE_DIR="${DBBOT_ROOT}/.dbbotctl"
readonly DBBOT_SNAPSHOT_DIR="${DBBOT_STATE_DIR}/snapshots"
readonly DBBOT_CACHE_DIR="${DBBOT_STATE_DIR}/cache"
readonly DBBOT_HISTORY_FILE="${DBBOT_STATE_DIR}/history.tsv"
readonly DBBOT_PORTABLE_ANSIBLE_HOME="${DBBOT_ROOT}/portable-ansible-v0.5.0-py3"
readonly DBBOT_PORTABLE_ANSIBLE_SETUP="${DBBOT_PORTABLE_ANSIBLE_HOME}/setup_portable_ansible.sh"
readonly DBBOT_ANSIBLE_PLAYBOOK="${DBBOT_PORTABLE_ANSIBLE_HOME}/ansible-playbook"
readonly DBBOTCTL_EXPORTERREGISTRAR_BIN="${DBBOTCTL_LIBEXEC_DIR}/exporterregistrar"
readonly DBBOT_RELEASE_OWNER="${DBBOT_RELEASE_OWNER:-fanderchan}"
readonly DBBOT_RELEASE_REPO="${DBBOT_RELEASE_REPO:-dbbot}"
readonly DBBOT_RELEASE_BASE_URL="${DBBOT_RELEASE_BASE_URL:-https://github.com/${DBBOT_RELEASE_OWNER}/${DBBOT_RELEASE_REPO}/releases/download}"
readonly DBBOT_RELEASE_API_BASE_URL="${DBBOT_RELEASE_API_BASE_URL:-https://api.github.com/repos/${DBBOT_RELEASE_OWNER}/${DBBOT_RELEASE_REPO}/releases}"

readonly -a DBBOT_MANAGED_ROOT_FILES=(
  "LICENSE"
  "NOTICE"
  "README.en.md"
  "README.md"
  "THIRD_PARTY_LICENSES.txt"
  "VERSION"
)

readonly -a DBBOT_MANAGED_ROOT_DIRS=(
  "bin"
  "clickhouse_ansible"
  "libexec"
  "monitoring_prometheus_ansible"
  "mysql_ansible"
  "portable-ansible-v0.5.0-py3"
)

readonly -a DBBOT_PRESERVE_PATHS=(
  "clickhouse_ansible/downloads"
  "clickhouse_ansible/inventory"
  "clickhouse_ansible/playbooks/logs"
  "clickhouse_ansible/playbooks/vars"
  "monitoring_prometheus_ansible/downloads"
  "monitoring_prometheus_ansible/inventory"
  "monitoring_prometheus_ansible/playbooks/common_config.yml"
  "monitoring_prometheus_ansible/playbooks/logs"
  "monitoring_prometheus_ansible/playbooks/vars"
  "mysql_ansible/downloads"
  "mysql_ansible/inventory"
  "mysql_ansible/playbooks/advanced_config.yml"
  "mysql_ansible/playbooks/common_config.yml"
  "mysql_ansible/playbooks/logs"
  "mysql_ansible/playbooks/vars"
)

dbbot_supports_color() {
  [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

dbbot_print() {
  local level="$1"
  local color="$2"
  local stream="$3"
  shift 3

  if dbbot_supports_color; then
    printf '\033[%sm[%s]\033[0m %s\n' "${color}" "${level}" "$*" >&"${stream}"
  else
    printf '[%s] %s\n' "${level}" "$*" >&"${stream}"
  fi
}

dbbot_info() {
  dbbot_print "INFO" "36" 1 "$@"
}

dbbot_warn() {
  dbbot_print "WARN" "33" 2 "$@"
}

dbbot_success() {
  dbbot_print "OK" "32" 1 "$@"
}

dbbot_stage() {
  local current="$1"
  local total="$2"
  shift 2
  dbbot_info "[${current}/${total}] $*"
}

dbbot_die() {
  dbbot_print "ERROR" "31" 2 "$@"
  exit 1
}

dbbot_require_no_args() {
  if (($# != 0)); then
    dbbot_die "unexpected arguments: $*"
  fi
}

dbbot_ensure_state_dirs() {
  mkdir -p "${DBBOT_SNAPSHOT_DIR}" "${DBBOT_CACHE_DIR}"
}

dbbot_current_version_line() {
  sed -n '1p' "${DBBOT_ROOT}/VERSION"
}

dbbot_current_version() {
  awk 'NR == 1 { print $2 }' "${DBBOT_ROOT}/VERSION"
}

dbbot_tag_from_version() {
  local version="$1"
  if [[ "${version}" == v* ]]; then
    printf '%s\n' "${version}"
  else
    printf 'v%s\n' "${version}"
  fi
}

dbbot_current_tag() {
  dbbot_tag_from_version "$(dbbot_current_version)"
}

dbbot_now_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

dbbot_has_command() {
  command -v "$1" >/dev/null 2>&1
}

dbbot_require_commands() {
  local command_name=""

  for command_name in "$@"; do
    if ! dbbot_has_command "${command_name}"; then
      dbbot_die "required command not found: ${command_name}"
    fi
  done
}

dbbot_abs_path() {
  local input_path="$1"

  if [[ "${input_path}" == /* ]]; then
    printf '%s\n' "${input_path}"
    return 0
  fi

  printf '%s/%s\n' "$(cd "$(dirname "${input_path}")" && pwd -P)" "$(basename "${input_path}")"
}

dbbot_validate_tag() {
  local tag="$1"

  if [[ ! "${tag}" =~ ^v[0-9A-Za-z.+-]+$ ]]; then
    dbbot_die "unsupported tag format: ${tag}"
  fi
}

dbbot_release_asset_name() {
  local tag="$1"
  printf 'dbbot-%s.tar.gz\n' "${tag}"
}

dbbot_http_get() {
  local url="$1"

  if dbbot_has_command curl; then
    curl -fsSL "${url}"
    return 0
  fi

  if dbbot_has_command wget; then
    wget -qO- "${url}"
    return 0
  fi

  dbbot_die "online operations require curl or wget"
}

dbbot_download_to() {
  local url="$1"
  local output_path="$2"

  mkdir -p "$(dirname "${output_path}")"

  if dbbot_has_command curl; then
    curl -fL --retry 3 --retry-delay 1 -o "${output_path}" "${url}"
    return 0
  fi

  if dbbot_has_command wget; then
    wget -O "${output_path}" "${url}"
    return 0
  fi

  dbbot_die "online operations require curl or wget"
}

dbbot_resolve_latest_tag() {
  dbbot_require_commands python3
  dbbot_http_get "${DBBOT_RELEASE_API_BASE_URL}/latest" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
tag = str(data.get("tag_name", "")).strip()
if not tag:
    raise SystemExit(1)
print(tag)
'
}

dbbot_download_release_package() {
  local tag="$1"
  local output_path="$2"
  local asset_name=""
  local asset_url=""

  dbbot_validate_tag "${tag}"
  asset_name="$(dbbot_release_asset_name "${tag}")"
  asset_url="${DBBOT_RELEASE_BASE_URL}/${tag}/${asset_name}"
  dbbot_download_to "${asset_url}" "${output_path}"
}

dbbot_package_root_name() {
  local package_path="$1"
  tar -tzf "${package_path}" | awk -F/ 'NR == 1 { first = $1 } END { if (first != "") print first; else exit 1 }'
}

dbbot_package_version() {
  local package_path="$1"
  tar -xOf "${package_path}" "dbbot/VERSION" | awk 'NR == 1 { print $2 }'
}

dbbot_validate_package() {
  local package_path="$1"
  local expected_tag="${2:-}"
  local package_root=""
  local package_version=""
  local package_tag=""
  local tar_listing=""

  [[ -f "${package_path}" ]] || dbbot_die "package not found: ${package_path}"
  tar_listing="$(tar -tzf "${package_path}")"

  package_root="$(dbbot_package_root_name "${package_path}")"
  if [[ "${package_root}" != "$(basename "${DBBOT_ROOT}")" ]]; then
    dbbot_die "package root ${package_root} does not match install root $(basename "${DBBOT_ROOT}")"
  fi

  grep -qx "${package_root}/README.md" <<<"${tar_listing}" || dbbot_die "package is missing ${package_root}/README.md"
  grep -qx "${package_root}/VERSION" <<<"${tar_listing}" || dbbot_die "package is missing ${package_root}/VERSION"
  grep -qx "${package_root}/portable-ansible-v0.5.0-py3/ansible-playbook" <<<"${tar_listing}" || \
    dbbot_die "package is missing ${package_root}/portable-ansible-v0.5.0-py3/ansible-playbook"

  package_version="$(dbbot_package_version "${package_path}")"
  [[ -n "${package_version}" ]] || dbbot_die "unable to read VERSION from package: ${package_path}"
  package_tag="$(dbbot_tag_from_version "${package_version}")"

  if [[ -n "${expected_tag}" && "${package_tag}" != "${expected_tag}" ]]; then
    dbbot_die "package version mismatch: expected ${expected_tag}, got ${package_tag}"
  fi
}

dbbot_write_metadata_file() {
  local file_path="$1"
  shift
  : > "${file_path}"

  while (($# > 0)); do
    if (($# < 2)); then
      dbbot_die "metadata requires key/value pairs"
    fi

    printf '%s=%q\n' "$1" "$2" >> "${file_path}"
    shift 2
  done
}

dbbot_append_history() {
  local timestamp="$1"
  local action="$2"
  local status="$3"
  local from_version="$4"
  local to_version="$5"
  local snapshot_id="$6"
  local source_ref="$7"
  local note="$8"

  dbbot_ensure_state_dirs

  if [[ ! -f "${DBBOT_HISTORY_FILE}" ]]; then
    printf 'timestamp\taction\tstatus\tfrom_version\tto_version\tsnapshot_id\tsource\tnote\n' > "${DBBOT_HISTORY_FILE}"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${timestamp}" \
    "${action}" \
    "${status}" \
    "${from_version}" \
    "${to_version}" \
    "${snapshot_id}" \
    "${source_ref}" \
    "${note}" >> "${DBBOT_HISTORY_FILE}"
}

dbbot_latest_snapshot_id() {
  if [[ ! -d "${DBBOT_SNAPSHOT_DIR}" ]]; then
    return 1
  fi

  find "${DBBOT_SNAPSHOT_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -n 1
}

dbbot_capture_paths() {
  local source_root="$1"
  local destination_root="$2"
  local manifest_path="${3:-}"
  local relpath=""

  mkdir -p "${destination_root}"
  if [[ -n "${manifest_path}" ]]; then
    : > "${manifest_path}"
  fi

  (
    cd "${source_root}"
    for relpath in "${DBBOT_PRESERVE_PATHS[@]}"; do
      if [[ -e "${relpath}" ]]; then
        cp -a --parents "${relpath}" "${destination_root}"
        if [[ -n "${manifest_path}" ]]; then
          printf '%s\n' "${relpath}" >> "${manifest_path}"
        fi
      fi
    done
  )
}

dbbot_remove_managed_paths() {
  local relpath=""

  for relpath in "${DBBOT_MANAGED_ROOT_DIRS[@]}"; do
    rm -rf "${DBBOT_ROOT}/${relpath}"
  done

  for relpath in "${DBBOT_MANAGED_ROOT_FILES[@]}"; do
    rm -f "${DBBOT_ROOT}/${relpath}"
  done
}

dbbot_snapshot_current_root() {
  local snapshot_tar="$1"
  local root_parent=""
  local root_name=""

  root_parent="$(dirname "${DBBOT_ROOT}")"
  root_name="$(basename "${DBBOT_ROOT}")"

  tar \
    -C "${root_parent}" \
    --exclude="${root_name}/.dbbotctl" \
    -czf "${snapshot_tar}" \
    "${root_name}"
}

dbbot_run_post_upgrade_checks() {
  local log_path="$1"
  local stream_live="${2:-0}"

  dbbot_require_commands python3
  mkdir -p "$(dirname "${log_path}")"
  : > "${log_path}"

  if ((stream_live)); then
    (
      set -euo pipefail

      printf '== ansible-playbook --version ==\n'
      python3 "${DBBOT_ANSIBLE_PLAYBOOK}" --version

      printf '\n== mysql syntax check ==\n'
      cd "${DBBOT_ROOT}/mysql_ansible/playbooks"
      python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.ini single_node.yml --syntax-check

      printf '\n== clickhouse deploy syntax check ==\n'
      cd "${DBBOT_ROOT}/clickhouse_ansible/playbooks"
      python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check

      printf '\n== clickhouse restore syntax check ==\n'
      python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check

      printf '\n== monitoring syntax check ==\n'
      cd "${DBBOT_ROOT}/monitoring_prometheus_ansible/playbooks"
      python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check
    ) > >(tee "${log_path}") 2>&1
    return 0
  fi

  (
    set -euo pipefail

    printf '== ansible-playbook --version ==\n'
    python3 "${DBBOT_ANSIBLE_PLAYBOOK}" --version

    printf '\n== mysql syntax check ==\n'
    cd "${DBBOT_ROOT}/mysql_ansible/playbooks"
    python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.ini single_node.yml --syntax-check

    printf '\n== clickhouse deploy syntax check ==\n'
    cd "${DBBOT_ROOT}/clickhouse_ansible/playbooks"
    python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check

    printf '\n== clickhouse restore syntax check ==\n'
    python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check

    printf '\n== monitoring syntax check ==\n'
    cd "${DBBOT_ROOT}/monitoring_prometheus_ansible/playbooks"
    python3 "${DBBOT_ANSIBLE_PLAYBOOK}" -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check
  ) >> "${log_path}" 2>&1
}
