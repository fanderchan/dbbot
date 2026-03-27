#!/usr/bin/env bash

dbbot_cmd_version() {
  dbbot_require_no_args "$@"

  printf 'dbbot: %s\n' "$(dbbot_current_version_line)"
  printf 'release_tag: %s\n' "$(dbbot_current_tag)"
  printf 'root: %s\n' "${DBBOT_ROOT}"
  printf 'state_dir: %s\n' "${DBBOT_STATE_DIR}"
  printf 'portable_ansible_home: %s\n' "${DBBOT_PORTABLE_ANSIBLE_HOME}"
  printf 'ansible_playbook: %s\n' "${DBBOT_ANSIBLE_PLAYBOOK}"
  printf 'exporterregistrar: %s\n' "${DBBOTCTL_EXPORTERREGISTRAR_BIN}"

  if dbbot_has_command python3 && [[ -e "${DBBOT_ANSIBLE_PLAYBOOK}" ]]; then
    local ansible_version_line=""

    if ansible_version_line="$(python3 "${DBBOT_ANSIBLE_PLAYBOOK}" --version 2>/dev/null | sed -n '1p')"; then
      printf 'portable_ansible_version: %s\n' "${ansible_version_line}"
    else
      printf 'portable_ansible_version: unavailable\n'
    fi
  fi
}
