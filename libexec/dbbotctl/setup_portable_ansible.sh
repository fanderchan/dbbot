#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBBOT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DBBOT_BIN_DIR="${DBBOT_ROOT}/bin"
PORTABLE_ANSIBLE_HOME="${DBBOT_ROOT}/portable-ansible"
PORTABLE_ANSIBLE_PLAYBOOK="${PORTABLE_ANSIBLE_HOME}/ansible-playbook"
PORTABLE_ANSIBLE_BIN="${PORTABLE_ANSIBLE_HOME}/ansible"
SSHPASS_SOURCE="${SCRIPT_DIR}/sshpass-x64"
BASHRC_FILE="${HOME}/.bashrc"

echoError() { echo -e "\033[31m$*\033[0m"; }
echoWarning() { echo -e "\033[33m$*\033[0m"; }
echoSuccess() { echo -e "\033[32m$*\033[0m"; }

upsert_bashrc_line() {
    local regex="$1"
    local line="$2"
    local temp_file=""

    temp_file="$(mktemp)"
    awk -v regex="${regex}" -v line="${line}" '
        BEGIN { replaced = 0 }
        $0 ~ regex {
            if (!replaced) {
                print line
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print line
            }
        }
    ' "${BASHRC_FILE}" > "${temp_file}"
    mv "${temp_file}" "${BASHRC_FILE}"
}

package_manager=""
if command -v dnf >/dev/null 2>&1; then
    package_manager="dnf"
elif command -v yum >/dev/null 2>&1; then
    package_manager="yum"
else
    echoError "Neither yum nor dnf was found; cannot bootstrap portable ansible dependencies."
    exit 1
fi

if [[ ! -f "${PORTABLE_ANSIBLE_PLAYBOOK}" ]]; then
    echoError "Portable ansible entrypoint not found: ${PORTABLE_ANSIBLE_PLAYBOOK}"
    exit 1
fi

if [[ ! -f "${PORTABLE_ANSIBLE_BIN}" ]]; then
    echoError "Portable ansible entrypoint not found: ${PORTABLE_ANSIBLE_BIN}"
    exit 1
fi

if [[ ! -f "${SSHPASS_SOURCE}" ]]; then
    echoError "Bundled sshpass binary not found: ${SSHPASS_SOURCE}"
    exit 1
fi

install_first_available_package() {
    local package_name=""

    for package_name in "$@"; do
        if "${package_manager}" -q list installed "${package_name}" >/dev/null 2>&1; then
            return 0
        fi
        if "${package_manager}" -q list available "${package_name}" >/dev/null 2>&1; then
            "${package_manager}" install -y "${package_name}"
            return 0
        fi
    done

    return 1
}

python3_has_selinux_binding() {
    python3 - <<'PY' >/dev/null 2>&1
import selinux
PY
}

"${package_manager}" install -y python3

if ! python3_has_selinux_binding; then
    if ! install_first_available_package python3-libselinux libselinux-python3; then
        echoError "Python3 SELinux bindings are missing, and no known package name was found."
        exit 1
    fi
fi

if ! python3_has_selinux_binding; then
    echoError "Python3 SELinux bindings are still unavailable after installation."
    exit 1
fi

touch "${BASHRC_FILE}"

upsert_bashrc_line '^alias ansible-playbook=' \
    "alias ansible-playbook=\"python3 ${PORTABLE_ANSIBLE_PLAYBOOK}\""
upsert_bashrc_line '^alias ansible=' \
    "alias ansible=\"python3 ${PORTABLE_ANSIBLE_BIN}\""
upsert_bashrc_line '^export PATH=\".*/dbbot(/libexec)?/bin:\\$PATH\"$' \
    "export PATH=\"${DBBOT_BIN_DIR}:\$PATH\""

if ! command -v sshpass >/dev/null 2>&1; then
    cp "${SSHPASS_SOURCE}" /usr/bin/sshpass
    chmod +x /usr/bin/sshpass
fi

echoSuccess "Portable Ansible dependencies are ready."
echoWarning "Please run 'source ~/.bashrc' to apply the changes in your current shell."
