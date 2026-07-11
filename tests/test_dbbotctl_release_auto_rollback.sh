#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

create_runtime_tree() {
  local install_root="$1"
  local version="$2"

  mkdir -p "${install_root}"
  cp -a "${repo_dir}/bin" "${install_root}/"
  cp -a "${repo_dir}/libexec" "${install_root}/"
  mkdir -p \
    "${install_root}/portable-ansible" \
    "${install_root}/mysql_ansible/playbooks" \
    "${install_root}/mysql_ansible/inventory" \
    "${install_root}/clickhouse_ansible/playbooks" \
    "${install_root}/clickhouse_ansible/inventory" \
    "${install_root}/monitoring_prometheus_ansible/playbooks" \
    "${install_root}/monitoring_prometheus_ansible/inventory"

  printf 'dbbot %s\nansible 2.10.17\n' "${version}" > "${install_root}/VERSION"
  printf 'source release %s\n' "${version}" > "${install_root}/README.md"
  printf 'preserved inventory\n' > "${install_root}/mysql_ansible/inventory/custom.ini"
}

write_source_ansible() {
  local install_root="$1"

  cat > "${install_root}/portable-ansible/ansible-playbook" <<'EOF'
#!/usr/bin/env python3
print("source checks passed")
EOF
  chmod +x "${install_root}/portable-ansible/ansible-playbook"
}

write_target_ansible() {
  local install_root="$1"
  local behavior="$2"

  case "${behavior}" in
    success)
      cat > "${install_root}/portable-ansible/ansible-playbook" <<'EOF'
#!/usr/bin/env python3
print("target checks passed")
EOF
      ;;
    delete_snapshot)
      cat > "${install_root}/portable-ansible/ansible-playbook" <<'EOF'
#!/usr/bin/env python3
from pathlib import Path

install_root = Path(__file__).resolve().parent.parent
for snapshot in (install_root / ".dbbotctl" / "snapshots").glob("*/root-before-upgrade.tar.gz"):
    snapshot.unlink()
raise SystemExit(42)
EOF
      ;;
    *)
      cat > "${install_root}/portable-ansible/ansible-playbook" <<'EOF'
#!/usr/bin/env python3
raise SystemExit(42)
EOF
      ;;
  esac
  chmod +x "${install_root}/portable-ansible/ansible-playbook"
}

build_target_package() {
  local case_dir="$1"
  local behavior="$2"
  local package_root="${case_dir}/package/dbbot"
  local package_path="${case_dir}/dbbot-v2.0.0.tar.gz"

  create_runtime_tree "${package_root}" "2.0.0"
  printf 'target release 2.0.0\n' > "${package_root}/README.md"
  write_target_ansible "${package_root}" "${behavior}"
  tar -C "${case_dir}/package" -czf "${package_path}" dbbot
  printf '%s\n' "${package_path}"
}

latest_snapshot_dir() {
  local install_root="$1"

  find "${install_root}/.dbbotctl/snapshots" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | sort \
    | tail -n 1
}

assert_history_entry() {
  local history_file="$1"
  local expected_note_prefix="$2"

  awk -F'\t' -v prefix="${expected_note_prefix}" '
    $2 == "upgrade" && $3 == "failed" && index($8, prefix) == 1 { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${history_file}"
}

run_upgrade_success_case() {
  local case_dir="${work_dir}/upgrade-success"
  local install_root="${case_dir}/live/dbbot"
  local package_path=""
  local output=""
  local rollback_output=""
  local snapshot_dir=""
  local snapshot_id=""
  local metadata_file=""

  create_runtime_tree "${install_root}" "1.0.0"
  write_source_ansible "${install_root}"
  package_path="$(build_target_package "${case_dir}" "success")"

  output="$("${install_root}/bin/dbbotctl" release upgrade --package "${package_path}" 2>&1)"
  grep -Fq "upgrade completed" <<<"${output}"
  grep -qx 'dbbot 2.0.0' "${install_root}/VERSION"
  grep -qx 'target release 2.0.0' "${install_root}/README.md"
  grep -qx 'preserved inventory' "${install_root}/mysql_ansible/inventory/custom.ini"

  snapshot_dir="$(latest_snapshot_dir "${install_root}")"
  metadata_file="${snapshot_dir}/metadata.env"
  grep -qx 'status=success' "${metadata_file}"
  grep -qx 'post_checks=passed' "${metadata_file}"
  [[ ! -e "${snapshot_dir}/upgrade-phase" ]]
  awk -F'\t' '
    $2 == "upgrade" && $3 == "success" && $8 == "package_replaced" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${install_root}/.dbbotctl/history.tsv"

  snapshot_id="$(basename "${snapshot_dir}")"
  rollback_output="$("${install_root}/bin/dbbotctl" release rollback "${snapshot_id}" --skip-checks 2>&1)"
  grep -Fq "rollback completed" <<<"${rollback_output}"
  grep -qx 'dbbot 1.0.0' "${install_root}/VERSION"
  grep -qx 'source release 1.0.0' "${install_root}/README.md"
  awk -F'\t' '
    $2 == "rollback" && $3 == "success" && $8 == "snapshot_restored" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${install_root}/.dbbotctl/history.tsv"
}

run_skip_checks_case() {
  local case_dir="${work_dir}/skip-checks"
  local install_root="${case_dir}/live/dbbot"
  local package_path=""
  local output=""
  local snapshot_dir=""
  local metadata_file=""

  create_runtime_tree "${install_root}" "1.0.0"
  write_source_ansible "${install_root}"
  package_path="$(build_target_package "${case_dir}" "fail_checks")"

  output="$("${install_root}/bin/dbbotctl" release upgrade --package "${package_path}" --skip-checks 2>&1)"
  grep -Fq "upgrade completed" <<<"${output}"
  grep -qx 'dbbot 2.0.0' "${install_root}/VERSION"

  snapshot_dir="$(latest_snapshot_dir "${install_root}")"
  metadata_file="${snapshot_dir}/metadata.env"
  grep -qx 'status=success' "${metadata_file}"
  grep -qx 'post_checks=skipped' "${metadata_file}"
}

run_rollback_success_case() {
  local case_dir="${work_dir}/rollback-success"
  local install_root="${case_dir}/live/dbbot"
  local package_path=""
  local output=""
  local rc=0
  local snapshot_dir=""
  local metadata_file=""

  create_runtime_tree "${install_root}" "1.0.0"
  write_source_ansible "${install_root}"
  package_path="$(build_target_package "${case_dir}" "fail_checks")"

  set +e
  output="$("${install_root}/bin/dbbotctl" release upgrade --package "${package_path}" --debug 2>&1)"
  rc=$?
  set -e

  [[ ${rc} -eq 42 ]] || { printf '%s\n' "${output}" >&2; return 1; }
  grep -Fq "automatic rollback completed" <<<"${output}"
  grep -qx 'dbbot 1.0.0' "${install_root}/VERSION"
  grep -qx 'source release 1.0.0' "${install_root}/README.md"
  grep -qx 'preserved inventory' "${install_root}/mysql_ansible/inventory/custom.ini"

  snapshot_dir="$(latest_snapshot_dir "${install_root}")"
  metadata_file="${snapshot_dir}/metadata.env"
  grep -qx 'status=failed' "${metadata_file}"
  grep -qx 'failure_phase=post_upgrade_checks' "${metadata_file}"
  grep -qx 'failure_exit_code=42' "${metadata_file}"
  grep -qx 'post_checks=failed' "${metadata_file}"
  grep -qx 'automatic_rollback=success' "${metadata_file}"
  grep -qx 'rollback_exit_code=0' "${metadata_file}"
  grep -qx 'rollback_checks=passed' "${metadata_file}"
  assert_history_entry "${install_root}/.dbbotctl/history.tsv" "auto_rollback_success"
}

run_rollback_failure_case() {
  local case_dir="${work_dir}/rollback-failure"
  local install_root="${case_dir}/live/dbbot"
  local package_path=""
  local output=""
  local rc=0
  local snapshot_dir=""
  local metadata_file=""

  create_runtime_tree "${install_root}" "1.0.0"
  write_source_ansible "${install_root}"
  package_path="$(build_target_package "${case_dir}" "delete_snapshot")"

  set +e
  output="$("${install_root}/bin/dbbotctl" release upgrade --package "${package_path}" 2>&1)"
  rc=$?
  set -e

  [[ ${rc} -eq 42 ]] || { printf '%s\n' "${output}" >&2; return 1; }
  grep -Fq "automatic rollback failed" <<<"${output}"
  grep -qx 'dbbot 2.0.0' "${install_root}/VERSION"
  grep -qx 'target release 2.0.0' "${install_root}/README.md"

  snapshot_dir="$(latest_snapshot_dir "${install_root}")"
  metadata_file="${snapshot_dir}/metadata.env"
  grep -qx 'status=failed' "${metadata_file}"
  grep -qx 'failure_phase=post_upgrade_checks' "${metadata_file}"
  grep -qx 'failure_exit_code=42' "${metadata_file}"
  grep -qx 'automatic_rollback=failed' "${metadata_file}"
  grep -qx 'rollback_checks=not_run' "${metadata_file}"
  assert_history_entry "${install_root}/.dbbotctl/history.tsv" "auto_rollback_failed"
}

run_upgrade_success_case
run_skip_checks_case
run_rollback_success_case
run_rollback_failure_case
