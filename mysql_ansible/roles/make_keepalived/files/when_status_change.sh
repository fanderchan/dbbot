#!/bin/bash
BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.


log_info "Keepalived switch status by notify and running"
log_info "Keepalived switch status $1 $2 $3 "