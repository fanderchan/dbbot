#!/usr/bin/env bash

dbbot_cmd_release_usage() {
  cat <<'EOF'
Usage:
  dbbotctl release history
  dbbotctl release upgrade (--latest | --tag <tag> | --package <path>) [--dry-run] [--skip-checks]
  dbbotctl release rollback [snapshot_id] [--skip-checks]
EOF
}

dbbot_release_history_usage() {
  cat <<'EOF'
Usage:
  dbbotctl release history
EOF
}

dbbot_release_upgrade_usage() {
  cat <<'EOF'
Usage:
  dbbotctl release upgrade (--latest | --tag <tag> | --package <path>) [--dry-run] [--skip-checks]

Options:
  --latest           Resolve the latest official GitHub release tag and download it
  --tag <tag>        Download a specific GitHub release tag, for example v0.2.0
  --package <path>   Use a local release tarball
  --dry-run          Validate the package and print the planned actions without changing files
  --skip-checks      Skip post-upgrade ansible version and syntax checks
EOF
}

dbbot_release_rollback_usage() {
  cat <<'EOF'
Usage:
  dbbotctl release rollback [snapshot_id] [--skip-checks]

If snapshot_id is omitted, the latest recorded snapshot is used.
EOF
}

dbbot_print_history_table() {
  local history_file="$1"

  awk -F'\t' '
    NR == 1 {
      printf "%-17s %-9s %-8s %-10s %-10s %-28s %-20s %s\n",
        "timestamp", "action", "status", "from", "to", "snapshot_id", "source", "note";
      next
    }
    {
      printf "%-17s %-9s %-8s %-10s %-10s %-28s %-20s %s\n",
        $1, $2, $3, $4, $5, $6, $7, $8;
    }
  ' "${history_file}"
}

dbbot_cmd_release_history() {
  dbbot_require_no_args "$@"

  printf 'current_version: %s\n' "$(dbbot_current_tag)"
  printf 'state_dir: %s\n' "${DBBOT_STATE_DIR}"

  if [[ -f "${DBBOT_HISTORY_FILE}" ]]; then
    printf '\nRecorded events:\n'
    dbbot_print_history_table "${DBBOT_HISTORY_FILE}"
  else
    printf '\nRecorded events:\n'
    printf '  no upgrade or rollback history recorded yet\n'
  fi

  if [[ -d "${DBBOT_SNAPSHOT_DIR}" ]]; then
    local latest_snapshot=""
    latest_snapshot="$(dbbot_latest_snapshot_id || true)"
    printf '\nLatest rollback snapshot: %s\n' "${latest_snapshot:-none}"
  else
    printf '\nLatest rollback snapshot: none\n'
  fi
}

dbbot_cmd_release_upgrade() {
  local dry_run=0
  local skip_checks=0
  local selector_count=0
  local requested_tag=""
  local package_path=""
  local source_ref=""
  local target_tag=""
  local target_version=""
  local current_version=""
  local current_tag=""
  local snapshot_id=""
  local snapshot_dir=""
  local metadata_file=""
  local snapshot_tar=""
  local preserve_stage=""
  local preserved_manifest=""
  local packaged_manifest=""
  local package_templates_dir=""
  local checks_log=""
  local created_at=""
  local history_timestamp=""
  local source_kind=""

  while (($# > 0)); do
    case "$1" in
      --latest)
        selector_count=$((selector_count + 1))
        source_kind="latest"
        shift
        ;;
      --tag)
        [[ $# -ge 2 ]] || dbbot_die "--tag requires a value"
        selector_count=$((selector_count + 1))
        source_kind="tag"
        requested_tag="$2"
        shift 2
        ;;
      --package)
        [[ $# -ge 2 ]] || dbbot_die "--package requires a value"
        selector_count=$((selector_count + 1))
        source_kind="package"
        package_path="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --skip-checks)
        skip_checks=1
        shift
        ;;
      help|-h|--help)
        dbbot_release_upgrade_usage
        return 0
        ;;
      *)
        dbbot_die "unknown release upgrade option: $1"
        ;;
    esac
  done

  [[ ${selector_count} -eq 1 ]] || dbbot_die "choose exactly one of --latest, --tag, or --package"
  dbbot_require_commands tar mktemp cp rm find python3

  current_version="$(dbbot_current_version)"
  current_tag="$(dbbot_current_tag)"
  dbbot_ensure_state_dirs

  case "${source_kind}" in
    latest)
      target_tag="$(dbbot_resolve_latest_tag)"
      dbbot_validate_tag "${target_tag}"
      package_path="${DBBOT_CACHE_DIR}/$(dbbot_release_asset_name "${target_tag}")"
      dbbot_info "downloading latest release ${target_tag}"
      dbbot_download_release_package "${target_tag}" "${package_path}"
      source_ref="latest:${target_tag}"
      ;;
    tag)
      dbbot_validate_tag "${requested_tag}"
      target_tag="${requested_tag}"
      package_path="${DBBOT_CACHE_DIR}/$(dbbot_release_asset_name "${target_tag}")"
      dbbot_info "downloading release ${target_tag}"
      dbbot_download_release_package "${target_tag}" "${package_path}"
      source_ref="tag:${target_tag}"
      ;;
    package)
      package_path="$(dbbot_abs_path "${package_path}")"
      source_ref="package:${package_path}"
      ;;
    *)
      dbbot_die "unsupported upgrade source"
      ;;
  esac

  dbbot_validate_package "${package_path}" "${target_tag:-}"
  target_version="$(dbbot_package_version "${package_path}")"
  target_tag="$(dbbot_tag_from_version "${target_version}")"

  if ((dry_run)); then
    printf 'mode: dry-run\n'
    printf 'current_version: %s\n' "${current_tag}"
    printf 'target_version: %s\n' "${target_tag}"
    printf 'package: %s\n' "${package_path}"
    printf 'source: %s\n' "${source_ref}"
    printf 'post_checks: %s\n' "$([[ ${skip_checks} -eq 1 ]] && printf 'skipped' || printf 'enabled')"
    printf 'managed_roots:\n'
    printf '  %s\n' "${DBBOT_MANAGED_ROOT_DIRS[@]}"
    printf 'managed_root_files:\n'
    printf '  %s\n' "${DBBOT_MANAGED_ROOT_FILES[@]}"
    printf 'preserved_paths:\n'
    printf '  %s\n' "${DBBOT_PRESERVE_PATHS[@]}"
    return 0
  fi

  created_at="$(dbbot_now_utc)"
  snapshot_id="${created_at}_${target_tag}"
  snapshot_dir="${DBBOT_SNAPSHOT_DIR}/${snapshot_id}"
  metadata_file="${snapshot_dir}/metadata.env"
  snapshot_tar="${snapshot_dir}/root-before-upgrade.tar.gz"
  preserve_stage="$(mktemp -d)"
  preserved_manifest="${snapshot_dir}/preserved-live-paths.txt"
  packaged_manifest="${snapshot_dir}/packaged-template-paths.txt"
  package_templates_dir="${snapshot_dir}/packaged-preserved-paths"
  checks_log="${snapshot_dir}/post-upgrade-checks.log"

  mkdir -p "${snapshot_dir}"
  dbbot_write_metadata_file "${metadata_file}" \
    snapshot_id "${snapshot_id}" \
    operation "upgrade" \
    status "in_progress" \
    created_at "${created_at}" \
    from_version "${current_version}" \
    to_version "${target_version}" \
    source_ref "${source_ref}" \
    package_path "${package_path}" \
    snapshot_tar "${snapshot_tar}" \
    post_checks "$([[ ${skip_checks} -eq 1 ]] && printf 'skipped' || printf 'pending')"

  dbbot_info "creating rollback snapshot ${snapshot_id}"
  dbbot_snapshot_current_root "${snapshot_tar}"

  dbbot_info "capturing preserved user state"
  dbbot_capture_paths "${DBBOT_ROOT}" "${preserve_stage}" "${preserved_manifest}"

  dbbot_info "replacing managed release files"
  dbbot_remove_managed_paths
  tar -C "$(dirname "${DBBOT_ROOT}")" -xzf "${package_path}"

  dbbot_capture_paths "${DBBOT_ROOT}" "${package_templates_dir}" "${packaged_manifest}"
  cp -a "${preserve_stage}/." "${DBBOT_ROOT}/"
  rm -rf "${preserve_stage}"

  if ((skip_checks)); then
    dbbot_info "post-upgrade checks skipped by option"
    dbbot_write_metadata_file "${metadata_file}" \
      snapshot_id "${snapshot_id}" \
      operation "upgrade" \
      status "success" \
      created_at "${created_at}" \
      completed_at "$(dbbot_now_utc)" \
      from_version "${current_version}" \
      to_version "${target_version}" \
      source_ref "${source_ref}" \
      package_path "${package_path}" \
      snapshot_tar "${snapshot_tar}" \
      post_checks "skipped"
  else
    dbbot_info "running post-upgrade checks"
    dbbot_run_post_upgrade_checks "${checks_log}"
    dbbot_write_metadata_file "${metadata_file}" \
      snapshot_id "${snapshot_id}" \
      operation "upgrade" \
      status "success" \
      created_at "${created_at}" \
      completed_at "$(dbbot_now_utc)" \
      from_version "${current_version}" \
      to_version "${target_version}" \
      source_ref "${source_ref}" \
      package_path "${package_path}" \
      snapshot_tar "${snapshot_tar}" \
      post_checks "passed" \
      checks_log "${checks_log}"
  fi

  history_timestamp="$(dbbot_now_utc)"
  dbbot_append_history "${history_timestamp}" "upgrade" "success" "${current_version}" "${target_version}" "${snapshot_id}" "${source_ref}" "package_replaced"

  dbbot_success "upgrade completed: ${current_tag} -> ${target_tag}"
  printf 'snapshot_id: %s\n' "${snapshot_id}"
  printf 'snapshot: %s\n' "${snapshot_tar}"
  printf 'templates_before_overlay: %s\n' "${package_templates_dir}"
  if ((skip_checks == 0)); then
    printf 'checks_log: %s\n' "${checks_log}"
  fi
}

dbbot_cmd_release_rollback() {
  local skip_checks=0
  local snapshot_id=""
  local snapshot_dir=""
  local metadata_file=""
  local snapshot_tar=""
  local current_version=""
  local rollback_target_version="unknown"
  local history_timestamp=""

  while (($# > 0)); do
    case "$1" in
      --skip-checks)
        skip_checks=1
        shift
        ;;
      help|-h|--help)
        dbbot_release_rollback_usage
        return 0
        ;;
      *)
        if [[ -n "${snapshot_id}" ]]; then
          dbbot_die "rollback accepts at most one snapshot_id"
        fi
        snapshot_id="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${snapshot_id}" ]]; then
    snapshot_id="$(dbbot_latest_snapshot_id || true)"
  fi

  [[ -n "${snapshot_id}" ]] || dbbot_die "no rollback snapshot available"

  snapshot_dir="${DBBOT_SNAPSHOT_DIR}/${snapshot_id}"
  metadata_file="${snapshot_dir}/metadata.env"
  snapshot_tar="${snapshot_dir}/root-before-upgrade.tar.gz"
  [[ -d "${snapshot_dir}" ]] || dbbot_die "snapshot not found: ${snapshot_id}"
  [[ -f "${snapshot_tar}" ]] || dbbot_die "snapshot archive missing: ${snapshot_tar}"

  if [[ -f "${metadata_file}" ]]; then
    # shellcheck disable=SC1090
    source "${metadata_file}"
    rollback_target_version="${from_version:-unknown}"
    snapshot_tar="${snapshot_tar:-${snapshot_dir}/root-before-upgrade.tar.gz}"
  fi

  current_version="$(dbbot_current_version)"
  dbbot_info "restoring snapshot ${snapshot_id}"

  dbbot_remove_managed_paths
  tar -C "$(dirname "${DBBOT_ROOT}")" -xzf "${snapshot_tar}"

  if ((skip_checks)); then
    dbbot_info "post-rollback checks skipped by option"
  else
    local rollback_checks_log="${snapshot_dir}/post-rollback-checks.log"
    dbbot_info "running post-rollback checks"
    dbbot_run_post_upgrade_checks "${rollback_checks_log}"
  fi

  history_timestamp="$(dbbot_now_utc)"
  dbbot_append_history "${history_timestamp}" "rollback" "success" "${current_version}" "${rollback_target_version}" "${snapshot_id}" "snapshot:${snapshot_id}" "snapshot_restored"

  dbbot_success "rollback completed: $(dbbot_tag_from_version "${current_version}") -> $(dbbot_tag_from_version "${rollback_target_version}")"
  printf 'snapshot_id: %s\n' "${snapshot_id}"
  printf 'restored_to: %s\n' "$(dbbot_tag_from_version "${rollback_target_version}")"
}

dbbot_cmd_release() {
  local subcommand="${1:-help}"

  case "${subcommand}" in
    help|-h|--help)
      dbbot_cmd_release_usage
      ;;
    history)
      shift
      dbbot_cmd_release_history "$@"
      ;;
    upgrade)
      shift
      dbbot_cmd_release_upgrade "$@"
      ;;
    rollback)
      shift
      dbbot_cmd_release_rollback "$@"
      ;;
    *)
      dbbot_die "unknown release subcommand: ${subcommand}"
      ;;
  esac
}
