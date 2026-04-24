#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

status=0

playbooks_to_lint="$(find playbooks -maxdepth 1 -type f -name '*.yml' \
  ! -name 'common_config.yml' \
  ! -name 'advanced_config.yml' \
  | sort)"

ansible-lint $playbooks_to_lint
if [ $? -ne 0 ]; then
  status=1
fi

ansible-lint roles
if [ $? -ne 0 ]; then
  status=1
fi

exit "$status"
