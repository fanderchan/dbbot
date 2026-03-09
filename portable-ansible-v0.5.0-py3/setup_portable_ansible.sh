#!/bin/bash
echoError() { echo -e "\033[31m$*\033[0m"; }      # red
echoWarning() { echo -e "\033[33m$*\033[0m"; }      # yellow
echoSuccess() { echo -e "\033[32m$*\033[0m"; }      # green

# install python3
yum install python3 -y

# setting ~/.bashrc
if ! grep -q 'alias ansible-playbook=' ~/.bashrc; then
    echo 'alias ansible-playbook="python3 '"$PWD"'/ansible-playbook"' >> ~/.bashrc
fi

if ! grep -q 'alias ansible=' ~/.bashrc; then
    echo 'alias ansible="python3 '"$PWD"'/ansible"' >> ~/.bashrc
fi

# install sshpass
if ! which sshpass > /dev/null; then
  cp sshpass-x64 /usr/bin/sshpass
  chmod +x /usr/bin/sshpass
fi

# warning
echoWarning "Please run 'source ~/.bashrc' to apply the changes in your current shell."

