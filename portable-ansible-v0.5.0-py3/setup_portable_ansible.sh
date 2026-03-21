#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echoError() { echo -e "\033[31m$*\033[0m"; }      # red
echoWarning() { echo -e "\033[33m$*\033[0m"; }      # yellow
echoSuccess() { echo -e "\033[32m$*\033[0m"; }      # green

package_manager=""
if command -v dnf >/dev/null 2>&1; then
    package_manager="dnf"
elif command -v yum >/dev/null 2>&1; then
    package_manager="yum"
else
    echoError "Neither yum nor dnf was found; cannot bootstrap portable ansible dependencies."
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

# install python3
"${package_manager}" install -y python3

# install python3 selinux binding for localhost delegated ansible modules
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

# setting ~/.bashrc
if ! grep -q 'alias ansible-playbook=' ~/.bashrc; then
    echo 'alias ansible-playbook="python3 '"$SCRIPT_DIR"'/ansible-playbook"' >> ~/.bashrc
fi

if ! grep -q 'alias ansible=' ~/.bashrc; then
    echo 'alias ansible="python3 '"$SCRIPT_DIR"'/ansible"' >> ~/.bashrc
fi

# install sshpass
if ! which sshpass > /dev/null; then
  cp "${SCRIPT_DIR}/sshpass-x64" /usr/bin/sshpass
  chmod +x /usr/bin/sshpass
fi

echoSuccess "Portable Ansible dependencies are ready."

# warning
echoWarning "Please run 'source ~/.bashrc' to apply the changes in your current shell."
