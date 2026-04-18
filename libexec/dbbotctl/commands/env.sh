#!/usr/bin/env bash

dbbot_cmd_env_usage() {
  cat <<'EOF'
Usage:
  dbbotctl env setup
EOF
}

dbbot_cmd_env_setup() {
  dbbot_require_no_args "$@"

  [[ -f "${DBBOT_PORTABLE_ANSIBLE_SETUP}" ]] || dbbot_die "missing ${DBBOT_PORTABLE_ANSIBLE_SETUP}"
  dbbot_info "running portable ansible setup"
  dbbot_info "this registers ansible aliases backed by ${DBBOT_PORTABLE_ANSIBLE_HOME} and prepends ${DBBOT_ROOT}/bin to PATH"
  bash "${DBBOT_PORTABLE_ANSIBLE_SETUP}"
}

dbbot_cmd_env() {
  local subcommand="${1:-help}"

  case "${subcommand}" in
    help|-h|--help)
      dbbot_cmd_env_usage
      ;;
    setup)
      shift
      dbbot_cmd_env_setup "$@"
      ;;
    *)
      dbbot_die "unknown env subcommand: ${subcommand}"
      ;;
  esac
}
