#!/usr/bin/env bash

dbbot_cmd_exporter_usage() {
  cat <<'EOF'
Usage:
  dbbotctl exporter register [exporterregistrar args]
  dbbotctl monitoring register [exporterregistrar args]

Commands:
  register  Register node, mysql, or router exporters in Prometheus

Examples:
  dbbotctl exporter register -t node -H 192.0.2.131 -s 192.0.2.161 -p '<your_ssh_password>'
  dbbotctl exporter register -t mysql -H 192.0.2.131 --db-port 3307 -s 192.0.2.161 -p '<your_ssh_password>'
  dbbotctl exporter register -t router -H 192.0.2.151 -s 192.0.2.161 -p '<your_ssh_password>'
EOF
}

dbbot_exporterregistrar_binary() {
  local preferred_bin="${DBBOTCTL_EXPORTERREGISTRAR_BIN}"
  local legacy_bin="${DBBOT_ROOT}/mysql_ansible/playbooks/exporterregistrar"

  if [[ -x "${preferred_bin}" ]]; then
    printf '%s\n' "${preferred_bin}"
    return 0
  fi

  if [[ -x "${legacy_bin}" ]]; then
    dbbot_warn "using legacy exporterregistrar path: ${legacy_bin}"
    printf '%s\n' "${legacy_bin}"
    return 0
  fi

  printf '%s\n' "${preferred_bin}"
}

dbbot_require_exporterregistrar_binary() {
  local exporterregistrar_bin=""

  exporterregistrar_bin="$(dbbot_exporterregistrar_binary)"
  [[ -x "${exporterregistrar_bin}" ]] || dbbot_die "missing executable exporterregistrar binary: ${exporterregistrar_bin}"
  printf '%s\n' "${exporterregistrar_bin}"
}

dbbot_cmd_exporter_register() {
  local exporterregistrar_bin=""

  exporterregistrar_bin="$(dbbot_require_exporterregistrar_binary)"

  if (($# == 0)); then
    "${exporterregistrar_bin}" register --help
    return 0
  fi

  "${exporterregistrar_bin}" register "$@"
}

dbbot_cmd_exporter() {
  local subcommand="${1:-help}"

  case "${subcommand}" in
    help|-h|--help)
      dbbot_cmd_exporter_usage
      ;;
    register)
      shift
      dbbot_cmd_exporter_register "$@"
      ;;
    *)
      dbbot_die "unknown exporter subcommand: ${subcommand}"
      ;;
  esac
}

dbbot_cmd_monitoring() {
  dbbot_cmd_exporter "$@"
}
