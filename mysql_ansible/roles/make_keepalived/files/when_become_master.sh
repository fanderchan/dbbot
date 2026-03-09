#!/bin/bash
BASE_HOME=$(dirname "$0")
source ${BASE_HOME}/common_setup  # Loading the common code section from 'common_setup', and 'common_setup' in turn loads the shared functions from 'common_functions'.

log_info "Keepalived becoming master. Starting to set local MySQL database to master role"
log_info "CMD: show master status,set global super_read_only = OFF;set global read_only = OFF,stop slave, reset slave all"

# Check whether the VIP exists
check_vip_existence
if [ ${WVIP_COUNT} -eq 0 ]; then
    log_warn "VIP ${WRITE_VIP} does not exist on local host. Checking if VIP exists on the remote host..."
else
    log_info "VIP ${WRITE_VIP} exists on local host ${LOCAL_HOST}. MySQL node is master, continuing execution."
fi

# Improvement: more robust remote host check
check_remote_host() {
    local host_status=0
    local mysql_status=0
    
    log_info "Checking remote host ${REMOTE_HOST} status..."
    
    # Check if the host is reachable
    ping -c 1 -W 2 ${REMOTE_HOST} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_info "Remote host ${REMOTE_HOST} is reachable"
        host_status=1
							 
        # Check if the MySQL service is available
        timeout 5 ${MYSQLPING_REMOTE_CMD} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_info "MySQL service on remote host ${REMOTE_HOST} is running"
            mysql_status=1
        else
            log_warn "MySQL service on remote host ${REMOTE_HOST} is NOT running"
        fi
    else
        log_warn "Remote host ${REMOTE_HOST} is NOT reachable"
    fi
    
    # Return status codes:
    # 0 - host unreachable
    # 1 - host reachable but MySQL unavailable
    # 2 - host reachable and MySQL available
    if [ ${host_status} -eq 0 ]; then
        return 0
    elif [ ${mysql_status} -eq 0 ]; then
        return 1
    else
        return 2
    fi
}

# Run remote host check
check_remote_host
remote_status=$?

case ${remote_status} in
    0)  # Host unreachable
        log_warn "Remote host ${REMOTE_HOST} is unreachable. Will set this host as master."
        ;;
    1)  # Host reachable but MySQL unavailable
        log_warn "MySQL service on remote host ${REMOTE_HOST} is not running. Will set this host as master."
        ;;
    2)  # Host reachable and MySQL available
        log_info "Remote host ${REMOTE_HOST} is reachable and MySQL service is running. Checking if it's a slave..."
        
        # Check whether remote MySQL is configured as a replica
        ${MYSQL_REMOTE_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/remote_slave.txt
        if [ -s ${sqlpath}/remote_slave.txt ]; then
            master_host=$(grep -w "Master_Host" ${sqlpath}/remote_slave.txt | awk -F": " '{print $2}')
            if [ -n "${master_host}" ]; then
                log_info "Remote MySQL on ${REMOTE_HOST} is a slave with Master_Host=${master_host}"
            else
                log_warn "Remote MySQL on ${REMOTE_HOST} has slave configuration but Master_Host is empty"
            fi
        else
            log_info "Remote MySQL on ${REMOTE_HOST} is not configured as a slave"
        fi
        safe_remove_file "${sqlpath}/remote_slave.txt"
        ;;
esac

log_info "Checking local MySQL slave status..."
${MYSQL_LOCAL_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/local_slave.txt

if [ $? -eq 0 ]; then
    cat ${sqlpath}/local_slave.txt
    log_info "Successfully retrieved slave status"
    
    slave_host=$(grep -w "Master_Host" ${sqlpath}/local_slave.txt | awk -F": " '{print $2}')
    
    if [ -n "${slave_host}" ]; then
        log_info "Local MySQL is configured as slave with Master_Host=${slave_host}. Will convert to master."
        
        # Record current master status
        ${MYSQL_LOCAL_CMD} -e "SHOW MASTER STATUS\G" > ${sqlpath}/old_master_status.txt
        
        # Set as primary
        ${MYSQL_LOCAL_CMD} -N -L -s -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
        if [ $? -eq 0 ]; then
            log_info "Successfully disabled read-only mode"
        else
            log_error "Failed to disable read-only mode"
        fi
        
        # Stop replication and reset
        ${MYSQL_LOCAL_CMD} -e "STOP SLAVE; RESET SLAVE ALL;"
        if [ $? -eq 0 ]; then
            log_info "Successfully stopped and reset slave configuration"
        else
            log_error "Failed to stop and reset slave configuration"
        fi
        
        # Verify operation result
        ${MYSQL_LOCAL_CMD} -e "SHOW VARIABLES LIKE '%read_only%'; SHOW SLAVE STATUS\G" > ${sqlpath}/verification.txt
        read_only_status=$(grep -w "read_only" ${sqlpath}/verification.txt | awk '{print $2}')
        super_read_only_status=$(grep -w "super_read_only" ${sqlpath}/verification.txt | awk '{print $2}')
        
        if [ "${read_only_status}" = "OFF" ] && [ "${super_read_only_status}" = "OFF" ]; then
            log_info "Successfully converted local MySQL to master role"
        else
            log_error "Failed to fully convert local MySQL to master role"
        fi
        
        # Clean up temporary files
        safe_remove_file "${sqlpath}/verification.txt"
        safe_remove_file "${sqlpath}/old_master_status.txt"
    else
        log_info "Local MySQL is not configured as slave, continuing execution"
    fi
    
    # Clean up temporary files
    safe_remove_file "${sqlpath}/local_slave.txt"
else
    log_error "Failed to get slave status from local MySQL"
fi

# If remote MySQL is available, configure it as a replica
if [ ${remote_status} -eq 2 ]; then
    log_info "Remote MySQL is available. Attempting to configure it as a slave..."
    
    # Fetch local master status
    ${MYSQL_LOCAL_CMD} -e "SHOW MASTER STATUS\G" > ${sqlpath}/master_status.txt
    if [ $? -eq 0 ] && [ -s ${sqlpath}/master_status.txt ]; then
        log_info "Successfully retrieved master status. Configuring remote host as slave..."
        
        # Temporarily allow writes on remote MySQL for configuration
        ${MYSQL_REMOTE_CMD} -e "SET GLOBAL super_read_only=OFF;"
        
        # Configure remote MySQL as a replica
        ${MYSQL_REMOTE_CMD} -e "STOP SLAVE; RESET SLAVE ALL; \
            CHANGE MASTER TO MASTER_HOST='${LOCAL_HOST}', \
            MASTER_USER='${REP_USER}', \
            MASTER_PASSWORD='${REP_PWD}', \
            MASTER_PORT=${MYSQL_PORT}, \
            MASTER_AUTO_POSITION=1; \
            START SLAVE; \
            SET GLOBAL read_only=ON; \
            SET GLOBAL super_read_only=ON;"
        
        if [ $? -eq 0 ]; then
            log_info "Successfully configured remote MySQL as slave"
            
            # Validate replica status
            ${MYSQL_REMOTE_CMD} -e "SHOW SLAVE STATUS\G" > ${sqlpath}/remote_slave_verify.txt
            
            IO_RUNNING=$(grep -w "Slave_IO_Running" ${sqlpath}/remote_slave_verify.txt | awk -F": " '{print $2}' | tr -d ' ')
            SQL_RUNNING=$(grep -w "Slave_SQL_Running" ${sqlpath}/remote_slave_verify.txt | awk -F": " '{print $2}' | tr -d ' ')
            
            if [ "${IO_RUNNING}" = "Yes" ] && [ "${SQL_RUNNING}" = "Yes" ]; then
                log_info "Remote MySQL slave threads are running correctly"
            else
                log_warn "Remote MySQL slave threads are not running correctly: IO_Thread=${IO_RUNNING}, SQL_Thread=${SQL_RUNNING}"
                
                # Attempt recovery
                ${MYSQL_REMOTE_CMD} -e "STOP SLAVE; START SLAVE;"
                log_info "Attempted to restart slave threads on remote MySQL"
            fi
            
            # Clean up temporary files
            safe_remove_file "${sqlpath}/remote_slave_verify.txt"
        else
            log_error "Failed to configure remote MySQL as slave"
        fi
        
        # Clean up temporary files
        safe_remove_file "${sqlpath}/master_status.txt"
    else
        log_error "Failed to get master status from local MySQL"
    fi
fi

log_info "Master status set by Keepalived. Exiting script."
