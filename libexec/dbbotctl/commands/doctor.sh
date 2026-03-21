#!/usr/bin/env bash

dbbot_doctor_report() {
  local status="$1"
  local label="$2"
  local message="$3"

  printf '%-5s %-22s %s\n' "${status}" "${label}" "${message}"
}

dbbot_cmd_doctor() {
  dbbot_require_no_args "$@"

  local failures=0
  local warnings=0
  local available_kb=""
  local ansible_version_line=""

  if [[ -d "${DBBOT_ROOT}" ]]; then
    dbbot_doctor_report "PASS" "install_root" "${DBBOT_ROOT}"
  else
    dbbot_doctor_report "FAIL" "install_root" "missing ${DBBOT_ROOT}"
    failures=$((failures + 1))
  fi

  if mkdir -p "${DBBOT_STATE_DIR}" >/dev/null 2>&1; then
    dbbot_doctor_report "PASS" "state_dir" "${DBBOT_STATE_DIR}"
  else
    dbbot_doctor_report "FAIL" "state_dir" "cannot create ${DBBOT_STATE_DIR}"
    failures=$((failures + 1))
  fi

  local required_commands=(bash tar python3 mktemp cp rm find)
  local command_name=""
  for command_name in "${required_commands[@]}"; do
    if dbbot_has_command "${command_name}"; then
      dbbot_doctor_report "PASS" "cmd:${command_name}" "$(command -v "${command_name}")"
    else
      dbbot_doctor_report "FAIL" "cmd:${command_name}" "not found"
      failures=$((failures + 1))
    fi
  done

  if dbbot_has_command curl || dbbot_has_command wget; then
    dbbot_doctor_report "PASS" "downloader" "online upgrade available"
  else
    dbbot_doctor_report "WARN" "downloader" "curl or wget missing, online upgrade unavailable"
    warnings=$((warnings + 1))
  fi

  if dbbot_has_command sha256sum; then
    dbbot_doctor_report "PASS" "sha256sum" "$(command -v sha256sum)"
  else
    dbbot_doctor_report "WARN" "sha256sum" "missing, package checksum verification unavailable"
    warnings=$((warnings + 1))
  fi

  if dbbot_has_command sshpass; then
    dbbot_doctor_report "PASS" "sshpass" "$(command -v sshpass)"
  else
    dbbot_doctor_report "WARN" "sshpass" "missing, playbooks using password auth may fail until env setup runs"
    warnings=$((warnings + 1))
  fi

  if [[ -f "${DBBOT_PORTABLE_ANSIBLE_SETUP}" ]]; then
    dbbot_doctor_report "PASS" "env_setup" "${DBBOT_PORTABLE_ANSIBLE_SETUP}"
  else
    dbbot_doctor_report "FAIL" "env_setup" "missing ${DBBOT_PORTABLE_ANSIBLE_SETUP}"
    failures=$((failures + 1))
  fi

  if [[ -e "${DBBOT_ANSIBLE_PLAYBOOK}" ]]; then
    if ansible_version_line="$(python3 "${DBBOT_ANSIBLE_PLAYBOOK}" --version 2>/dev/null | sed -n '1p')"; then
      dbbot_doctor_report "PASS" "portable_ansible" "${ansible_version_line}"
    else
      dbbot_doctor_report "FAIL" "portable_ansible" "python3 ${DBBOT_ANSIBLE_PLAYBOOK} --version failed"
      failures=$((failures + 1))
    fi
  else
    dbbot_doctor_report "FAIL" "portable_ansible" "missing ${DBBOT_ANSIBLE_PLAYBOOK}"
    failures=$((failures + 1))
  fi

  available_kb="$(df -Pk "${DBBOT_ROOT}" | awk 'NR == 2 { print $4 }')"
  if [[ -n "${available_kb}" ]]; then
    dbbot_doctor_report "PASS" "disk_free" "$((available_kb / 1024)) MB available"
  fi

  printf '\nSummary: %s failure(s), %s warning(s)\n' "${failures}" "${warnings}"

  if ((failures > 0)); then
    exit 1
  fi
}
