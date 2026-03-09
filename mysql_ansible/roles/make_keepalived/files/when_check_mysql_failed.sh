#!/bin/bash
BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.

log_info "==== MySQL service check failed, starting self-healing operations ===="

# Modularize script logic to improve readability and robustness
diagnose_local_mysql() {
    log_info "Diagnosing local MySQL service status..."
    
    # Try to determine if local MySQL service is running
    timeout 5 ${MYSQLPING_LOCAL_CMD} >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_info "Local MySQL service process is running but may have other issues"
        return 0
    else
        log_warn "Local MySQL service process is not responding to ping command"
        return 1
    fi
}

restart_local_mysql() {
    restart_mysql_service
    
    # Wait for MySQL service to start
    local max_wait=30
    local count=0
    while [ $count -lt $max_wait ]; do
        timeout 5 ${MYSQLPING_LOCAL_CMD} >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_info "MySQL service restart successful"
            return 0
        fi
        log_info "Waiting for MySQL service to start, waited ${count} seconds..."
        sleep 1
        ((count++))
    done
    
    log_error "MySQL service restart failed, no response after ${max_wait} seconds"
    return 1
}

check_remote_mysql() {
    log_info "Checking remote MySQL service status..."
    
    # First check if MySQL on VIP is available
    timeout 5 ${MYSQLPING_VIP_CMD} >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_info "Detected MySQL service on VIP ${WRITE_VIP} is running normally"
        REMOTE_AVAILABLE=1
        REMOTE_CHECK_METHOD="VIP"
        return 0
    else
        log_warn "Detected MySQL service on VIP ${WRITE_VIP} is unavailable, trying direct connection to remote MySQL host"
        
        # Try direct connection to remote MySQL host
        timeout 5 ${MYSQLPING_REMOTE_CMD} >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_info "Detected MySQL service on remote host ${REMOTE_HOST} is running normally"
            REMOTE_AVAILABLE=1
            REMOTE_CHECK_METHOD="DIRECT"
            return 0
        else
            log_warn "Detected MySQL service on remote host ${REMOTE_HOST} is unavailable"
            REMOTE_AVAILABLE=0
            return 1
        fi
    fi
}

# Create working directory
if [ ! -d ${sqlpath} ]; then
    mkdir -p ${sqlpath} || {
        log_error "Cannot create working directory: ${sqlpath}"
        exit 1
    }
fi

# Initialize variables
REMOTE_AVAILABLE=0
REMOTE_CHECK_METHOD=""
LOCAL_STATUS=0
LOCAL_REPAIRABLE=0
VIP_HOLDER=""

# Check local MySQL status
diagnose_local_mysql
LOCAL_STATUS=$?

# If local MySQL is unavailable, try to restart
if [ ${LOCAL_STATUS} -eq 1 ]; then
    if [ "${RESTART_MYSQL_SERVICE_ON_FAIL}" = "true" ]; then
        log_info "RESTART_MYSQL_SERVICE_ON_FAIL is set to true, attempting to restart MySQL service..."
        restart_local_mysql
        LOCAL_STATUS=$?
    else
        log_warn "RESTART_MYSQL_SERVICE_ON_FAIL is set to false, skipping MySQL restart"
    fi
fi

#### Unfinished feature, no self-healing scenarios identified yet ####
# # If local MySQL is still unavailable, check if it can be repaired
# if [ ${LOCAL_STATUS} -eq 1 ]; then
#     log_warn "Local MySQL service still unavailable, checking filesystem and error logs..."
    
#     # Check disk space
#     DISK_SPACE=$(df -h ${MYSQL_DATADIR} | awk 'NR==2 {print $5}' | sed 's/%//')
#     if [ ${DISK_SPACE} -ge 99 ]; then
#         log_error "MySQL data directory has insufficient disk space, usage: ${DISK_SPACE}%"
#         LOCAL_REPAIRABLE=0
#     else
#         # Check for critical errors in error log
#         if grep -q "Corruption|Fatal|ERROR 1045" ${MYSQL_ERRORLOG} 2>/dev/null; then
#             log_error "Critical errors found in MySQL error log, manual intervention may be required"
#             LOCAL_REPAIRABLE=0
#         else
#             log_info "No critical errors found, attempting one-time MySQL repair measures"
#             # Additional repair measures can be added here, such as innodb recovery
#             LOCAL_REPAIRABLE=1
#         fi
#     fi
# fi

# Check remote MySQL status
check_remote_mysql

# Decide on action to take
if [ ${LOCAL_STATUS} -eq 0 ]; then
    log_info "Local MySQL service is available, checking if it's a master or slave..."
    
    # Check if VIP is on local host
    check_vip_existence
    if [ ${WVIP_COUNT} -eq 1 ]; then
        log_info "VIP ${WRITE_VIP} is on local host ${LOCAL_HOST}, this node should be master"
        VIP_HOLDER="LOCAL"
        
        # Check if master role is configured correctly
        ${MYSQL_LOCAL_CMD} -e "SHOW VARIABLES LIKE 'read_only'" > ${sqlpath}/read_only_state.txt
        if grep -q "OFF" ${sqlpath}/read_only_state.txt; then
            log_info "Local MySQL correctly configured as master mode (read-write mode)"
            
            # Check if slave configuration exists
            ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/local_slave_status.txt
            if [ -s ${sqlpath}/local_slave_status.txt ]; then
                log_warn "Local MySQL configured as master but slave configuration still exists, executing reset slave to fix"
                ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; RESET SLAVE ALL;"
                log_info "Slave configuration reset completed"
            fi
        else
            log_warn "Local MySQL configured incorrectly, should be master but not set to read-write mode, executing fix"
            ${MYSQL_LOCAL_CMD} -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
            log_info "Local MySQL has been set to read-write mode"
        fi
    else
        log_info "VIP ${WRITE_VIP} is not on local host ${LOCAL_HOST}, this node should be slave"
        
        # Check remote MySQL availability
        if [ ${REMOTE_AVAILABLE} -eq 1 ]; then
            log_info "Remote MySQL is available, confirming local should be slave"
            VIP_HOLDER="REMOTE"
            
            # Check if slave role is correctly configured
            ${MYSQL_LOCAL_CMD} -e "SHOW VARIABLES LIKE 'read_only'" > ${sqlpath}/read_only_state.txt
            if grep -q "ON" ${sqlpath}/read_only_state.txt; then
                log_info "Local MySQL correctly configured as slave mode (read-only mode)"
                
                # Check replication status
                ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/local_slave_status.txt
                IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/local_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/local_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                
                if [ "${IO_RUNNING}" = "Yes" ] && [ "${SQL_RUNNING}" = "Yes" ]; then
                    log_info "Replication is running normally"
                else
                    log_warn "Replication not running properly: IO_Thread=${IO_RUNNING}, SQL_Thread=${SQL_RUNNING}"
                    log_info "Attempting to fix replication..."
                    
                    # Check for errors
                    LAST_ERROR=$(grep -w "Last_SQL_Error" ${sqlpath}/local_slave_status.txt | awk -F": " '{$1=""; print $0}' | tr -d ' ')
                    if [ -n "${LAST_ERROR}" ]; then
                        log_warn "SQL error found: ${LAST_ERROR}"
                        
                        # Record error details before attempt to restart replication
                        ERROR_LOG_FILE="${LOGFILE_PATH}/replication_errors.log"
                        {
                            echo "===== Replication Error Detected at $(date +'%F %T') ====="
                            echo "Host: ${LOCAL_HOST}"
                            echo "Error: ${LAST_ERROR}"
                            echo "IO_Thread: ${IO_RUNNING}, SQL_Thread: ${SQL_RUNNING}"
                            ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" >> ${ERROR_LOG_FILE}
                            echo "Action: Attempting to restart replication"
                            echo "----------------------------------------"
                        } >> ${ERROR_LOG_FILE}
                        
                        # Always attempt to restart replication regardless of error type
                        log_info "Attempting to restart replication despite error..."
                        ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; START SLAVE;"
                        echo "$(date +'%F %T') WARNING: Replication error detected and replication restarted - ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
                    else
                        log_info "No specific error found, but threads not running. Attempting to restart replication..."
                        ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; START SLAVE;"
                    fi
                    
                    # Verify if restart fixed the issue
                    sleep 2
                    ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/fixed_slave_status.txt
                    NEW_IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/fixed_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                    NEW_SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/fixed_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                    
                    if [ "${NEW_IO_RUNNING}" = "Yes" ] && [ "${NEW_SQL_RUNNING}" = "Yes" ]; then
                        log_info "Successfully fixed replication"
                    else
                        log_warn "Replication fix failed, may need to reconfigure slave"
                        
                        # Reconfigure slave when remote connection is available
                        if [ "${REMOTE_CHECK_METHOD}" = "VIP" ]; then
                            MASTER_HOST=${WRITE_VIP}
                        else
                            MASTER_HOST=${REMOTE_HOST}
                        fi
                        
                        log_info "Using host ${MASTER_HOST} to reconfigure slave..."
                        
                        # Get master status
                        if [ "${REMOTE_CHECK_METHOD}" = "VIP" ]; then
                            ${MYSQL_VIP_CMD} -e "SHOW MASTER STATUS\G" > ${sqlpath}/remote_master_status.txt
                        else
                            ${MYSQL_REMOTE_CMD} -e "SHOW MASTER STATUS\G" > ${sqlpath}/remote_master_status.txt
                        fi
                        
                        # Reconfigure slave
                        ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_USER='${REP_USER}', MASTER_PASSWORD='${REP_PWD}', MASTER_PORT=${MYSQL_PORT}, MASTER_AUTO_POSITION=1; START SLAVE;"
                        
                        # Verify reconfiguration
                        sleep 2
                        ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/reconfigured_slave_status.txt
                        NEW_IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/reconfigured_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                        NEW_SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/reconfigured_slave_status.txt | awk -F": " '{print $2}' | tr -d ' ')
                        
                        if [ "${NEW_IO_RUNNING}" = "Yes" ] && [ "${NEW_SQL_RUNNING}" = "Yes" ]; then
                            log_info "Successfully reconfigured replication"
                        else
                            log_error "Replication reconfiguration failed, manual intervention required"
                            echo "$(date +'%F %T') CRITICAL: Replication reconfiguration failed - ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
                        fi
                    fi
                fi
            else
                log_warn "Local MySQL configured incorrectly, should be slave but not set to read-only mode, executing fix"
                ${MYSQL_LOCAL_CMD} -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"
                log_info "Local MySQL has been set to read-only mode"
            fi
        else
            log_warn "Remote MySQL unavailable, cannot confirm master-slave relationship"
            VIP_HOLDER="UNKNOWN"
        fi
    fi
else
    # Case when local MySQL is unavailable
    log_warn "Local MySQL service is unavailable and cannot be repaired"
    
    if [ ${REMOTE_AVAILABLE} -eq 1 ]; then
        log_info "Remote MySQL is available, consider switching to remote MySQL"
        VIP_HOLDER="REMOTE"
    else
        log_error "Both local and remote MySQL are unavailable, system is in completely unavailable state"
        VIP_HOLDER="NONE"
        echo "$(date +'%F %T') CRITICAL: Both local and remote MySQL are unavailable!" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
    fi
fi

# Boundary condition handling: Check and handle binary log issues
handle_binlog_issues() {
    if [ ${LOCAL_STATUS} -eq 0 ]; then
        log_info "Checking binary log issues..."
        
        # Check binary log space
        BINLOG_DIR=$(${MYSQL_LOCAL_CMD} -e "SHOW VARIABLES LIKE 'log_bin_basename'" | awk 'NR==2 {print $2}' | xargs dirname)
        BINLOG_SPACE=$(du -sm ${BINLOG_DIR} 2>/dev/null | awk '{print $1}')
        
        if [ -n "${BINLOG_SPACE}" ] && [ ${BINLOG_SPACE} -gt 5000 ]; then
            log_warn "Binary logs using excessive disk space: ${BINLOG_SPACE}MB"
            
            # Get current binary log file
            ${MYSQL_LOCAL_CMD} -e "SHOW MASTER STATUS\G" > ${sqlpath}/binlog_status.txt
            CURRENT_BINLOG=$(grep -w "File" ${sqlpath}/binlog_status.txt | awk -F": " '{print $2}' | tr -d ' ')
            
            if [ -n "${CURRENT_BINLOG}" ]; then
                log_info "Current binary log file: ${CURRENT_BINLOG}"
                
                # Keep the 5 most recent binary log files
                ${MYSQL_LOCAL_CMD} -e "PURGE BINARY LOGS TO '${CURRENT_BINLOG}' MINUS 5;"
                if [ $? -eq 0 ]; then
                    log_info "Successfully purged old binary log files"
                else
                    log_warn "Failed to purge binary log files"
                fi
            fi
        fi
        
        # Check if binary logging is enabled
        ${MYSQL_LOCAL_CMD} -e "SHOW VARIABLES LIKE 'log_bin'" > ${sqlpath}/binlog_enabled.txt
        if grep -q "OFF" ${sqlpath}/binlog_enabled.txt; then
            log_error "Binary logging is not enabled, replication will not work properly"
            echo "$(date +'%F %T') CRITICAL: Binary logging not enabled - ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
        fi
    fi
}

# Handle binary log issues
handle_binlog_issues

# Data consistency verification
if [ ${LOCAL_STATUS} -eq 0 ] && [ ${REMOTE_AVAILABLE} -eq 1 ]; then
    log_info "Performing data consistency verification..."
    
    if [ "${REMOTE_CHECK_METHOD}" = "VIP" ]; then
        MASTER_HOST=${WRITE_VIP}
    else
        MASTER_HOST=${REMOTE_HOST}
    fi
    
    if verify_data_consistency "${MASTER_HOST}" "${LOCAL_HOST}"; then
        log_info "Data consistency verification passed"
    else
        log_warn "Data consistency verification failed, GTID mismatch"
        echo "$(date +'%F %T') WARNING: Data consistency verification failed - ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
    fi
fi

# Clean up temporary files
log_info "Cleaning up temporary files..."
for temp_file in ${sqlpath}/*.txt; do
    safe_remove_file "${temp_file}"
done

# Provide summary based on check results
log_info "==== MySQL service check and repair summary ===="
log_info "Local MySQL status: $([ ${LOCAL_STATUS} -eq 0 ] && echo "Available" || echo "Unavailable")"
log_info "Remote MySQL status: $([ ${REMOTE_AVAILABLE} -eq 0 ] && echo "Unavailable" || echo "Available(${REMOTE_CHECK_METHOD})")"
log_info "VIP location: ${VIP_HOLDER}"

if [ ${LOCAL_STATUS} -eq 0 ]; then
    if [ "${VIP_HOLDER}" = "LOCAL" ]; then
        log_info "Current node is a properly functioning master"
    elif [ "${VIP_HOLDER}" = "REMOTE" ]; then
        log_info "Current node is a properly functioning slave"
    else
        log_warn "Current node's role cannot be determined"
    fi
else
    log_error "Current node's MySQL is unavailable, manual intervention required"
fi

log_info "==== MySQL service check and repair operations completed ===="