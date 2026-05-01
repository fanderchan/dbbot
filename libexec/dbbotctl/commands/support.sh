#!/usr/bin/env bash

dbbot_cmd_support() {
  if [[ $# -eq 0 || "${1:-}" == "help" ]]; then
    set -- --help
  fi

  dbbot_require_commands python3
  python3 "${DBBOTCTL_LIBEXEC_DIR}/support.py" "${DBBOT_ROOT}" "$@"
}
