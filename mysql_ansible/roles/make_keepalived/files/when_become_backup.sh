#!/bin/bash
BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.

log_info "Keepalived transitioning to backup status, configuring local MySQL database slave if not already set."

## Improved: Using more reliable VIP check method
check_vip_existence
if [ ${WVIP_COUNT} -eq 1 ]; then
    log_info "VIP ${WRITE_VIP} exists on local host ${LOCAL_HOST}. MySQL node is master, no need to configure as slave."
    log_info "Keepalived ending backup status, exiting script execution."
    exit 0
else
    log_warn "VIP ${WRITE_VIP} not found on local host ${LOCAL_HOST}. MySQL node is slave, continuing with slave configuration."
fi

## Improved: Using more reliable MySQL service check instead of just pinging VIP
check_remote_mysql_service() {
    local check_status=0
    local mysql_status=0
    local max_attempts=3
    local attempt=1
    
    log_info "Checking remote MySQL service on VIP ${WRITE_VIP}..."
    
    # First check network connectivity
    while [ ${attempt} -le ${max_attempts} ]; do
        # Use TCP connection to check if MySQL port is reachable, more reliable
        timeout 2 bash -c "echo >/dev/tcp/${WRITE_VIP}/${MYSQL_PORT}" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            check_status=1
            log_info "MySQL port ${MYSQL_PORT} on VIP ${WRITE_VIP} is reachable (attempt ${attempt}/${max_attempts})"
            break
        else
            log_warn "MySQL port ${MYSQL_PORT} on VIP ${WRITE_VIP} is not reachable (attempt ${attempt}/${max_attempts})"
            sleep 2
            ((attempt++))
        fi
    done
    
    # If network connection is good, further check MySQL service
    if [ ${check_status} -eq 1 ]; then
        # Try to connect to MySQL service
        timeout 5 ${MYSQLADMIN_CMD} -u${MYSQL_HA_USER} -P${MYSQL_PORT} -h${WRITE_VIP} ping >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            mysql_status=1
            log_info "MySQL service on VIP ${WRITE_VIP} is running properly"
        else
            log_warn "MySQL service on VIP ${WRITE_VIP} is not responding properly"
        fi
    fi
    
    # Return MySQL service status
    return ${mysql_status}
}

# Check remote MySQL service
check_remote_mysql_service
remote_mysql_status=$?

if [ ${remote_mysql_status} -eq 1 ]; then
    log_info "Remote MySQL service on VIP ${WRITE_VIP} is available, continuing with slave configuration."
else
    log_warn "Remote MySQL service on VIP ${WRITE_VIP} is not available."
    log_info "Will attempt to check the actual master host directly."
    
    # Try to check the host directly
    timeout 5 ${MYSQLPING_REMOTE_CMD} >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_info "MySQL service on master host ${REMOTE_HOST} is available, continuing with slave configuration."
    else
        log_warn "MySQL service on master host ${REMOTE_HOST} is not available. No slave configuration will be done."
        log_warn "ALERT: Both VIP and direct master MySQL are unavailable. This could indicate a split-brain situation."
        # Send alerts here, e.g., write to special log file or trigger external monitoring system
        echo "$(date +'%F %T') CRITICAL: MySQL service unreachable at both VIP ${WRITE_VIP} and master ${REMOTE_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
        log_info "Keepalived ending backup status, exiting script execution."
        exit 0
    fi
fi
 
# Check if the remote MySQL is alive using mysqladmin ping
REMOTE_MYSQL_CHECK=$(timeout 5 ${MYSQLPING_REMOTE_CMD} 2>/dev/null)
alive_string="${REMOTE_MYSQL_CHECK:-connection failed}"

if [ "${alive_string}" != "mysqld is alive" ]; then
    log_warn "Remote MySQL on host ${REMOTE_HOST} is not alive: ${alive_string}"
    log_info "Backup status ended by keepalived. Exiting script."
    exit 0
else
    log_info "Remote MySQL on host ${REMOTE_HOST} is alive: ${alive_string}. Checking if it is master."
    slave_string=$(${MYSQL_REMOTE_CMD} -N -L -s -e "show slave status" 2>/dev/null)
    
    if [ -n "${slave_string}" ]; then
        log_warn "Remote host ${REMOTE_HOST} is a slave and doesn't require slave configuration."
        # Improved: Not just exit, but also send notifications and record abnormal status
        log_warn "ALERT: Unexpected configuration - remote host is a slave! This may indicate incorrect roles."
        echo "$(date +'%F %T') WARNING: Remote host ${REMOTE_HOST} is a slave, not a master as expected" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
        
        # Get more diagnostic information
        ${MYSQL_REMOTE_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/remote_slave_status.txt
        log_info "Remote slave status captured in ${sqlpath}/remote_slave_status.txt for diagnosis"
        log_info "Backup status ended by keepalived. Exiting script."
        exit 0
    else
        log_info "Remote host ${REMOTE_HOST} is in master role. Continue to set slave policy."
    fi
fi

log_info "Fetching local MySQL slave status..."
${MYSQL_LOCAL_CMD} -e "show slave status \G" > ${sqlpath}/local_slave.txt

if [ $? -eq 0 ]; then
    cat ${sqlpath}/local_slave.txt
    log_info "Successfully got \`show slave status\`."
    slave_host=$(grep -w "Master_Host" ${sqlpath}/local_slave.txt | awk -F": " '{print $2}')   
    if [ -n "${slave_host}" ]; then
        log_info "Local host is already configured as slave with Master_Host=${slave_host}"
        
        # Improved: Verify replication is running normally
        IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/local_slave.txt | awk -F": " '{print $2}')
        SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/local_slave.txt | awk -F": " '{print $2}')
        
        if [ "${IO_RUNNING}" != "Yes" ] || [ "${SQL_RUNNING}" != "Yes" ]; then
            log_warn "Replication threads not running properly: IO_Thread=${IO_RUNNING}, SQL_Thread=${SQL_RUNNING}"
            log_info "Attempting to fix replication..."
            
            # Try to fix replication
            ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; START SLAVE;"
            sleep 2
            
            # Verify fix results
            ${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/fixed_slave_status.txt
            NEW_IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/fixed_slave_status.txt | awk -F": " '{print $2}')
            NEW_SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/fixed_slave_status.txt | awk -F": " '{print $2}')
            
            if [ "${NEW_IO_RUNNING}" = "Yes" ] && [ "${NEW_SQL_RUNNING}" = "Yes" ]; then
                log_info "Successfully fixed replication threads"
            else
                log_warn "Failed to fix replication threads. Manual intervention may be required."
                # Record alert
                echo "$(date +'%F %T') WARNING: Slave threads not running on ${LOCAL_HOST}. Manual check required." >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
            fi
            
            # Clean up temporary files
            safe_remove_file "${sqlpath}/fixed_slave_status.txt"
        else
            log_info "Replication is running normally"
        fi
    else
        log_warn "Local host is not yet configured as slave. Master_Host=${slave_host}"
        log_info "Starting slave configuration for local host..."
        ${MYSQL_LOCAL_CMD} -N -L -s -e "set global super_read_only=OFF;set global read_only=ON;show variables like '%read_only';"
        ${MYSQL_LOCAL_CMD} -e "CHANGE MASTER TO MASTER_HOST = '${REMOTE_HOST}', MASTER_USER = '${REP_USER}', MASTER_PASSWORD = '${REP_PWD}',MASTER_PORT=${MYSQL_PORT},MASTER_AUTO_POSITION = 1;reset slave;start slave;"        
        if [ $? -eq 0 ]; then
            log_info "Slave configuration completed for local host."
            ${MYSQL_LOCAL_CMD} -e "set global super_read_only=ON;show variables like 'super_read_only';show variables like 'read_only';show slave status \G"
            
            # Improved: Verify data consistency
            if verify_data_consistency "${REMOTE_HOST}" "${LOCAL_HOST}"; then
                log_info "Initial data consistency check passed"
            else
                log_warn "Initial data consistency check failed - GTID mismatch"
            fi
        else
            log_warn "Failed to configure local host as slave."
            # Record alert
            echo "$(date +'%F %T') ERROR: Failed to configure slave on ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
        fi
    fi
    # Use safe removal function
    safe_remove_file "${sqlpath}/local_slave.txt"
else
    log_warn "Failed to fetch local MySQL slave status."
    # Record alert
    echo "$(date +'%F %T') ERROR: Failed to fetch slave status on ${LOCAL_HOST}" >> ${LOGFILE_PATH}/mysql_keepalived_alerts.log
fi

log_info "Backup status ended by keepalived. Exiting script."