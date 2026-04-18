#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBBOT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DBBOT_BIN_DIR="${DBBOT_ROOT}/bin"
PORTABLE_ANSIBLE_HOME="${DBBOT_ROOT}/portable-ansible"
PORTABLE_ANSIBLE_PLAYBOOK="${PORTABLE_ANSIBLE_HOME}/ansible-playbook"
PORTABLE_ANSIBLE_BIN="${PORTABLE_ANSIBLE_HOME}/ansible"
PORTABLE_ANSIBLE_EXTRAS="${PORTABLE_ANSIBLE_HOME}/ansible/extras"
SSHPASS_SOURCE="${SCRIPT_DIR}/sshpass-x64"
OS_NAME="$(uname -s)"

echoError() { echo -e "\033[31m$*\033[0m"; }
echoWarning() { echo -e "\033[33m$*\033[0m"; }
echoSuccess() { echo -e "\033[32m$*\033[0m"; }

upsert_rc_line() {
    local rc_file="$1"
    local regex="$2"
    local line="$3"
    local temp_file=""

    touch "${rc_file}"
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
    ' "${rc_file}" > "${temp_file}"
    mv "${temp_file}" "${rc_file}"
}

register_shell_rc() {
    local rc_file="$1"

    upsert_rc_line "${rc_file}" '^alias ansible-playbook=' \
        "alias ansible-playbook=\"python3 ${PORTABLE_ANSIBLE_PLAYBOOK}\""
    upsert_rc_line "${rc_file}" '^alias ansible=' \
        "alias ansible=\"python3 ${PORTABLE_ANSIBLE_BIN}\""
    upsert_rc_line "${rc_file}" '^export PATH=\".*/dbbot(/libexec)?/bin:\\$PATH\"$' \
        "export PATH=\"${DBBOT_BIN_DIR}:\$PATH\""
}

validate_portable_ansible() {
    local ansible_version_output=""

    if ! command -v python3 >/dev/null 2>&1; then
        echoError "python3 was not found; portable ansible requires python3 on the control host."
        exit 1
    fi

    if ! ansible_version_output="$(python3 "${PORTABLE_ANSIBLE_PLAYBOOK}" --version 2>&1)"; then
        echoError "Portable ansible failed to start: python3 ${PORTABLE_ANSIBLE_PLAYBOOK} --version"
        printf '%s\n' "${ansible_version_output}" >&2
        exit 1
    fi
}

if [[ ! -e "${PORTABLE_ANSIBLE_PLAYBOOK}" ]]; then
    echoError "Portable ansible entrypoint not found: ${PORTABLE_ANSIBLE_PLAYBOOK}"
    exit 1
fi

if [[ ! -e "${PORTABLE_ANSIBLE_BIN}" ]]; then
    echoError "Portable ansible entrypoint not found: ${PORTABLE_ANSIBLE_BIN}"
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

portable_python_has_passlib() {
    PYTHONPATH="${PORTABLE_ANSIBLE_EXTRAS}:${PORTABLE_ANSIBLE_HOME}/ansible${PYTHONPATH:+:${PYTHONPATH}}" \
        python3 - <<'PY' >/dev/null 2>&1
import passlib.hash
PY
}

ensure_macos_passlib() {
    if portable_python_has_passlib; then
        return 0
    fi

    if ! python3 -m pip --version >/dev/null 2>&1; then
        echoError "passlib is required for password_hash on macOS, but python3 pip is unavailable."
        echoError "Install Python 3 with pip, then rerun: dbbotctl env setup"
        exit 1
    fi

    mkdir -p "${PORTABLE_ANSIBLE_EXTRAS}"
    python3 -m pip install \
        --disable-pip-version-check \
        --no-warn-script-location \
        -t "${PORTABLE_ANSIBLE_EXTRAS}" \
        "passlib==1.7.4"

    if ! portable_python_has_passlib; then
        echoError "passlib is still unavailable in ${PORTABLE_ANSIBLE_EXTRAS} after installation."
        exit 1
    fi
}

setup_linux_control_host() {
    local package_manager=""

    if command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
    else
        echoError "Neither yum nor dnf was found; cannot bootstrap portable ansible dependencies."
        exit 1
    fi

    if [[ ! -f "${SSHPASS_SOURCE}" ]]; then
        echoError "Bundled sshpass binary not found: ${SSHPASS_SOURCE}"
        exit 1
    fi

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

    validate_portable_ansible
    register_shell_rc "${HOME}/.bashrc"

    if ! command -v sshpass >/dev/null 2>&1; then
        cp "${SSHPASS_SOURCE}" /usr/bin/sshpass
        chmod +x /usr/bin/sshpass
    fi

    echoSuccess "Portable Ansible dependencies are ready."
    echoWarning "Please run 'source ~/.bashrc' to apply the changes in your current shell."
}

setup_macos_control_host() {
    if ! command -v tar >/dev/null 2>&1; then
        echoError "tar was not found; install the macOS Command Line Tools, then rerun dbbotctl env setup."
        exit 1
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        echoError "ssh was not found; install the macOS Command Line Tools, then rerun dbbotctl env setup."
        exit 1
    fi

    validate_portable_ansible
    ensure_macos_passlib
    register_shell_rc "${HOME}/.zshrc"
    register_shell_rc "${HOME}/.bashrc"

    if ! command -v sshpass >/dev/null 2>&1; then
        echoWarning "sshpass was not found. SSH key authentication is recommended on macOS."
        echoWarning "Inventories using ansible_ssh_pass require a macOS-compatible sshpass installed separately."
    fi

    echoSuccess "Portable Ansible dependencies are ready for macOS control host usage."
    echoWarning "Please run 'source ~/.zshrc' or 'source ~/.bashrc' to apply the changes in your current shell."
}

case "${OS_NAME}" in
    Darwin)
        setup_macos_control_host
        ;;
    Linux)
        setup_linux_control_host
        ;;
    *)
        echoError "Unsupported control host OS: ${OS_NAME}"
        exit 1
        ;;
esac
