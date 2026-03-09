#!/bin/bash

BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.

log_info "======== KEEPALIVED MYSQL CHECK STARTED ========"

# If the write VIP is on this node and this node is master
# Use a more reliable VIP check without relying on grep
WVIP_COUNT=$(ip addr show | awk -v vip="${WRITE_VIP}" '$0 ~ vip {count++} END {print count+0}')

if [ "${WVIP_COUNT}" -eq 1 ]; then
    log_info "Node role: MASTER (VIP ${WRITE_VIP} exists on ${LOCAL_HOST})"
    VIP_DETAILS=$(ip addr show | grep -w "${WRITE_VIP}" | head -1)
    log_info "VIP interface: ${VIP_DETAILS}"
else
    log_info "Node role: SLAVE (VIP ${WRITE_VIP} not on ${LOCAL_HOST})"
fi

# Check mysql is alived function
check_mysql_alive() {
    local i=0
    local COUNTER_RES=0
    local MYSQL_ALIVE_CHKLOG="${LOGFILE_PATH}/mysql_alive_$(date +%Y%m%d%H%M%S)$RANDOM"
    MYSQL_ALIVED=0

    # Execute health check SQL with timeout
    log_info "Executing health check query against local MySQL..."
    nohup ${MYSQL_LOCAL_CMD} -N -L -s -e "${CHECK_SQL}" > "${MYSQL_ALIVE_CHKLOG}" 2>/dev/null &

    while [ $i -lt ${CHECK_TIME} ]; do
        i=$((i + 1))
        sleep 1
        if [ -s "${MYSQL_ALIVE_CHKLOG}" ]; then
            COUNTER_RES=$(wc -l < "${MYSQL_ALIVE_CHKLOG}")
            COUNTER_RES=${COUNTER_RES:-0}
            if [ ${COUNTER_RES} -gt 0 ]; then
                MYSQL_ALIVED=1
                log_info "Health check result: $(cat ${MYSQL_ALIVE_CHKLOG})"
                rm -f "${MYSQL_ALIVE_CHKLOG}"
                break
            fi
        fi
    done

    # If no response after timeout
    if [ ${MYSQL_ALIVED} -eq 0 ]; then
        log_warn "MySQL health check timed out after ${CHECK_TIME} seconds"
        [ -f "${MYSQL_ALIVE_CHKLOG}" ] && rm -f "${MYSQL_ALIVE_CHKLOG}"
    fi
}

# Main health check loop
ic=1
while [ $ic -le ${CHECK_COUNT} ]; do
    log_info "Health check attempt ${ic}/${CHECK_COUNT}"
    check_mysql_alive
    
    if [ ${MYSQL_ALIVED} -eq 1 ]; then
        log_info "RESULT: MySQL is RUNNING"
        log_info "======== KEEPALIVED MYSQL CHECK COMPLETED [SUCCESS] ========"
        exit 0
    else
        log_warn "RESULT: MySQL is DOWN (attempt ${ic}/${CHECK_COUNT})"
        
        if [ ${ic} -eq ${CHECK_COUNT} ]; then
            log_error "All health check attempts failed - initiating failover"
            log_info "======== KEEPALIVED MYSQL CHECK COMPLETED [FAILURE] ========"
            exit 1
        fi
    fi
    ic=$((ic + 1))
    # Add small delay between attempts
    [ $ic -le ${CHECK_COUNT} ] && sleep 1
done
