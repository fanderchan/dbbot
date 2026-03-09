#!/bin/bash
BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.

log_info "Keepalived shuts down normally, triggering the normal shutdown of the local MySQL node."

${MYSQLSHUTDOWN_LOCAL_CMD}
if (( $? == 0 )); then
    log_info "LOCAL MySQL shutdown completed"
else
    log_info "LOCAL MySQL shutdown failed. Pls check it."