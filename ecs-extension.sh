#!/bin/bash -eu
script_start_time=$(date +%s)
non_exec_cmd=${exec_cmd#"exec "}
CLUSTER_IPS=""
DISCOVERY_PORT=5000
BOLT_PORT=7687
BACKUP_PORT=6362
# get more info from AWS environment:
# - instance im running on
# - my IP
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id/)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4/)
# the way to get IP from containers with awsvpc networking
# INSTANCE_IP=$(cat /etc/hosts | tail -1 | awk {'print $1'})
UPGRADE_MODE=${UPGRADE_MODE:-false}

DEFAULT_DATABASE=neo4j
# needed for backward compatibility and cluster upgrade
BACKUP_NAME=neo4j-backup

cloudmap_discover_instances() {
    aws servicediscovery list-instances \
                    --service-id $CLOUDMAP_SERVICE_ID \
                    --query "Instances[].Attributes.AWS_INSTANCE_IPV4" \
                    --output text \
                    --region $AWS_REGION
}


cloudmap_discover() {
    # skip discovery in the upgrade mode
    if [ "$UPGRADE_MODE" == "true" ]; then
        echo "Skipping instances discovery, because of UPGRADE_MODE=true"
        return 0
    fi

    local count=0
    local backoff=20
    local ips=""

    # TODO: replica can join when there are 2 nodes
    until [ $count -eq ${NEO4J_causal__clustering_minimum__core__cluster__size__at__formation:-3} ] || [ $backoff -eq 0 ]
    do
        ips=$(cloudmap_discover_instances | tr '\t' '\n')
        count=$(wc -l <<< "$ips")
        ((backoff--))
        echo "Expected ${NEO4J_causal__clustering_minimum__core__cluster__size__at__formation:-3} ips and got $count"
        echo "Discovered ips:" $ips
        echo "Discovery tries $backoff left"
        sleep 3
    done

    if [ $backoff -eq 0 ]; then
        echo "Exiting"
        exit 1
    else
        echo "Discovery complete"
    fi

    for IP in $ips;
    do
        if [ "$IP" == "" ] ; then
            continue
        fi

        if [ "${CLUSTER_IPS}" != "" ] ; then
           CLUSTER_IPS=$CLUSTER_IPS,
        fi
        CLUSTER_IPS=$CLUSTER_IPS$IP:$DISCOVERY_PORT
    done
}

backup() { # https://neo4j.com/docs/operations-manual/current/backup/performing/
    BACKUP_DIR=${BACKUP_DIR:-/tmp/}

    # cleaning old backups data before running daily backups
    # to run full backup instead of incremental one
    if [ "$(date +%H)" == "00" ]; then
        rm -rfv $BACKUP_DIR/*
    fi

    
    # TODO: backup all available databases?
    # for ls ${NEO4J_DATA_ROOT}/databases/; do
    echo "Creating Neo4j DB backup from node ${BACKUP_FROM:- }"
    neo4j-admin backup \
        --backup-dir=$BACKUP_DIR/  \
        --database=$DEFAULT_DATABASE \
        ${BACKUP_FROM:+--from=$BACKUP_FROM}:${BACKUP_PORT} \
        ${PAGE_CACHE:+--pagecache=$PAGE_CACHE} \
        --check-consistency=false \
        --verbose

    BACKUP_FILE=$BACKUP_NAME-$(date +%s).zip

    pushd $BACKUP_DIR

    # rename dir for backward compatibility
    rm -rf $BACKUP_NAME  
    mv $DEFAULT_DATABASE $BACKUP_NAME 
    zip -r $BACKUP_FILE $BACKUP_NAME

    echo "Zipping backup content in file $BACKUP_FILE"
    s3_path=""
    # Upload file to the "/daily" dir if backup run at 00 hour
    if [ "$(date +%H)" == "00" ]; then
        s3_path="s3://$AWS_BACKUP_BUCKET/daily"
    else
        s3_path="s3://$AWS_BACKUP_BUCKET/hourly"
    fi

    # upload backup file as not-verified because we didn't check
    # consistency yet
    aws s3 cp --no-progress $BACKUP_FILE $s3_path/not-verified/
    echo "Backup file is ready but not verified yet: $s3_path/not-verified/$BACKUP_FILE"
    du -h $BACKUP_FILE

    if [ $UPGRADE_MODE != "true" ]; then
        # check consitency after file is uploaded to s3, because it may take a loooooong time
        neo4j-admin check-consistency --backup=$BACKUP_NAME --verbose
        aws s3 mv $s3_path/not-verified/$BACKUP_FILE $s3_path/$BACKUP_FILE
    fi

    echo "Success! Backup file is ready: $s3_path/$BACKUP_FILE"
    rm -rf $BACKUP_FILE
}

# https://neo4j.com/docs/operations-manual/current/backup/restoring/#backup-restoring-causal-cluster
restore_neo4j() {
    echo "Replacing healthcheck with fake one, during the beckup restore process"
    cp -v /healthcheck.sh  /healthcheck.real.sh 
    cp -v /healthcheck.fake.sh /healthcheck.sh

    BACKUP_DIR=${NEO4J_DATA_ROOT}/downloads
    mkdir -p ${BACKUP_DIR}

    BACKUP_PATH="$BACKUP_DIR/_snapshot.zip"
    if [ ${SNAPSHOT_PATH: -5} == ".dump" ]; then
       BACKUP_PATH="$BACKUP_DIR/_snapshot.dump" 
    fi

    S3_PATH="s3://$SNAPSHOT_PATH"

    # we are going to save imported backup markers on the disk
    # to avoid futher backup imports on container restart
    # but only for CORE servers with the mounted EBS volume into NEO4J_DATA_ROOT 
    if [ ! -z "${NEO4J_DATA_ROOT:-}" ]; then 
        BACKUP_MARKERS_PATH=$NEO4J_DATA_ROOT/restored_backups
        MARKER=$BACKUP_MARKERS_PATH/$(basename $SNAPSHOT_PATH).done 

        # checking for existing backup markers
        if [ -f "$MARKER" ]; then
            echo "Found backup marker $MARKER, omitting backup restore procedure"
            return
        fi
    fi

    if [ "$SNAPSHOT_PATH" == "latest" ]; then
        echo "Looking for the latest backup"
        LATEST_BACKUP=$(aws s3 ls s3://$AWS_BACKUP_BUCKET | tail -n 1 | awk '{print $4}')
        if [ -n "$LATEST_BACKUP" ]; then
            S3_PATH="s3://$AWS_BACKUP_BUCKET/$LATEST_BACKUP"
        else
            echo "Latest bacukp not found"
        fi
    fi

    rm -rf $BACKUP_DIR/* 
    echo "Restore initiated. Source: $S3_PATH"

    aws s3 cp --no-progress $S3_PATH $BACKUP_PATH
    local status=$?
    if [ "$status" -ne 0 ] ; then
        echo "Error: failed to copy snapshot $SNAPSHOT_PATH from S3"
        return 1
    fi

    echo "Successfully copied snapshot $SNAPSHOT_PATH from S3!"
    if [ ${SNAPSHOT_PATH: -4} == ".zip" ]; then 
        unzip $BACKUP_PATH -d $BACKUP_DIR | grep -v "debug"
        chown -R ${userid}:${groupid} $BACKUP_PATH
        rm -rfv ${BACKUP_PATH}
    fi

    echo "Trying to unbind node from previous cluster memberships"
    ${non_exec_cmd} neo4j-admin unbind

    # https://neo4j.com/docs/migration-guide/4.0/online-backup-copy-database/#tutorial-online-backup-copy-database
    if [ "$UPGRADE_MODE" == "true" ]; then
        echo "Upgrading database from snapshot"
        rm -rf $NEO4J_DATA_ROOT/data/databases/neo4j 
        neo4j-admin copy \
            --from-path="$BACKUP_DIR/$BACKUP_NAME" \
            --from-pagecache="${NEO4J_dbms_memory_pagecache_size}" \
            --to-database=$DEFAULT_DATABASE \
            --to-pagecache="${NEO4J_dbms_memory_heap_max__size}" \
            --force --verbose
        status=$?
        if [ "$status" -ne 0 ] ; then
            echo "Error: failed to upgrade from snapshot."
            return 1
        fi

        echo "Now dumping restored data, so it can be imported into other nodes"
        DUMP_FILE=/tmp/$DEFAULT_DATABASE-$(date +%s).dump
        neo4j-admin dump --database=$DEFAULT_DATABASE  --to=$DUMP_FILE
        aws s3 cp --no-progress $DUMP_FILE s3://$AWS_BACKUP_BUCKET/dumps/
        echo "Uploaded dump file to s3"
    elif [ ${SNAPSHOT_PATH: -5} == ".dump" ]; then 
        echo "Loading dump..."
        ${non_exec_cmd} neo4j-admin load --from=$BACKUP_PATH --database=$DEFAULT_DATABASE --force
        status=$?
        if [ "$status" -ne 0 ] ; then
            echo "Error: failed to load db dump"
            return 1
        fi
    else
        echo "Running restore..."
        ${non_exec_cmd} neo4j-admin restore --from="$BACKUP_DIR/$BACKUP_NAME" --database=$DEFAULT_DATABASE --force
        status=$?
        if [ "$status" -ne 0 ] ; then
            echo "Error: failed to restore from snapshot."
            return 1
        fi
    fi


    echo "Enforcing permissions"
    chown -R ${userid}:${groupid} $NEO4J_HOME/data/

    echo "Restore completed. Cleaning up downloaded files..."
    rm -rf ${BACKUP_DIR}

    if [ ! -z "${NEO4J_DATA_ROOT:-}" ]; then 
        echo "Marking successful backup restoration with marker $MARKER"
        echo "Further restoration of same backup version will be skipped"
        mkdir -p $BACKUP_MARKERS_PATH
        touch $MARKER 
    fi

    echo "Bring back real healthcheck script"
    cp -v /healthcheck.sh /healthcheck.fake.sh
    cp -v /healthcheck.real.sh /healthcheck.sh 
}

# copy of the piece of code from the original docker-entrypoint.sh
# https://github.com/neo4j/docker-neo4j-publish/blob/5a80e2a88fb92e4b10b12d79b28a8070ab2d13fb/3.5.4/enterprise/docker-entrypoint.sh#L188-L206
# needed to be able to save configurations after we modified it in the our extension script
save_config() {
    # list env variables with prefix NEO4J_ and create settings from them
    unset NEO4J_AUTH NEO4J_SHA256 NEO4J_TARBALL
    for i in $( set | grep ^NEO4J_ | awk -F'=' '{print $1}' | sort -rn ); do
        setting=$(echo ${i} | sed 's|^NEO4J_||' | sed 's|_|.|g' | sed 's|\.\.|_|g')
        value=$(echo ${!i})
        # Don't allow settings with no value or settings that start with a number (neo4j converts settings to env variables and you cannot have an env variable that starts with a number)
        if [[ -n ${value} ]]; then
            if [[ ! "${setting}" =~ ^[0-9]+.*$ ]]; then
                if grep -q -F "${setting}=" "${NEO4J_HOME}"/conf/neo4j.conf; then
                    # Remove any lines containing the setting already
                    sed --in-place "/^${setting}=.*/d" "${NEO4J_HOME}"/conf/neo4j.conf
                fi
                # Then always append setting to file
                echo "${setting}=${value}" >> "${NEO4J_HOME}"/conf/neo4j.conf
            else
                echo >&2 "WARNING: ${setting} not written to conf file because settings that start with a number are not permitted"
            fi
        fi
    done
}


# copy of the part of the docker-entrypoint.sh script
# which does the initial user configuratio with custom edits
# copy is needed, because running the "neo4j-admin set-initial-password"
# will create $NEO4J_HOME/data direcotry, with the root permissions and BEFORE
# we mounted into our external EBS volume
setup_users() {
    # set the neo4j initial password only if you run the database server
    if [ "${NEO4J_ADMIN_PASSWORD:-}" == "none" ]; then
        NEO4J_dbms_security_auth__enabled=false
    elif [ -z "${NEO4J_ADMIN_PASSWORD:-}" ]; then
        echo >&2 "Missing NEO4J_ADMIN_PASSWORD. If you don't want to configure authentification please set the NEO4J_ADMIN_PASSWORD=none"
        exit 1
    else
        password="${NEO4J_ADMIN_PASSWORD}"
        if [ "${password}" == "neo4j" ]; then
            echo >&2 "Invalid value for password. It cannot be 'neo4j', which is the default."
            exit 1
        fi
        
        # Will exit with error if users already exist (and print a message explaining that)
        ${non_exec_cmd} bin/neo4j-admin set-initial-password "${password}" || true

        ## Start of custom code block
        user=neo4j # admin user is always "neo4j"
        guest_user=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f1)
        guest_password=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f2)

        # as soon as we get credentials, we can start waiting for BOLT protocol to warm it up
        # upon startup.
        echo "Scheduling init tasks..."
        NEO4J_USERNAME="${user}" NEO4J_PASSWORD="${password}" GUEST_USERNAME="${guest_user}" GUEST_PASSWORD="${guest_password}" bash /init-db.sh &
        echo "Scheduling init tasks: Done."
        ## Start of custom code block
    fi

    unset NEO4J_ADMIN_PASSWORD
}

configure() {
    # unset the variable NEO4J_dbms_directories_logs, which is set by parent docker-entrypoint.sh and pointing to /logs
    NEO4J_dbms_directories_logs=$NEO4J_HOME/logs

    # setting custom variables
    # high availability cluster settings.
    # https://neo4j.com/docs/operations-manual/current/reference/configuration-settings/#configuration-settings
    NEO4J_dbms_mode=${NEO4J_dbms_mode:-CORE}
    NEO4J_dbms_default__listen__address=0.0.0.0
    NEO4J_dbms_default__advertised__address=$INSTANCE_IP

    NEO4J_causal__clustering_discovery__advertised__address=$INSTANCE_IP:5000 
    NEO4J_causal__clustering_transaction__advertised__address=$INSTANCE_IP:6000 
    NEO4J_causal__clustering_raft__advertised__address=$INSTANCE_IP:7000
    NEO4J_causal__clustering_initial__discovery__members=${NEO4J_causal__clustering_initial__discovery__members:-core.neo4j.testing:0}
    NEO4J_causal__clustering_discovery__type=${NEO4J_causal__clustering_discovery__type:-SRV}

    NEO4J_dbms_backup_listen__address=${NEO4J_dbms_backup_address:-0.0.0.0}:$BACKUP_PORT
    NEO4J_dbms_allow__upgrade=${NEO4J_dbms_allow__upgrade:-false}
    
    NEO4J_apoc_export_file_enabled=true

    # enable TTL support and run query to delete every x mins
    NEO4J_apoc_ttl_enabled=${NEO4J_apoc_ttl_enabled:-true}
    NEO4J_apoc_ttl_schedule=${NEO4J_apoc_ttl_schedule:-300}

    NEO4J_dbms_security_causal__clustering__status__auth__enabled=false

    # not configurable for now.
    NEO4J_dbms_security_procedures_unrestricted=apoc.*

    # metrics rotation settings since they consume a lot of space
    NEO4J_metrics_csv_rotation_keep__number=10
    NEO4J_metrics_csv_rotation_size=10000000 # 10 MB


    if [ $NEO4J_causal__clustering_discovery__type == "LIST" ]; then
        NEO4J_causal__clustering_initial__discovery__members=$CLUSTER_IPS
    fi

    if [ $NEO4J_QUERY_LOG == "enabled" ]; then # https://neo4j.com/docs/operations-manual/current/monitoring/logging/query-logging/
        # Log allocated bytes for the executed queries being logged.
        NEO4J_dbms_logs_query_allocation__logging__enabled=${NEO4J_dbms_logs_query_allocation__logging__enabled:-true}
        # Log executed queries that take longer than the configured threshold, dbms.logs.query.threshold.
        NEO4J_dbms_logs_query_enabled=${NEO4J_dbms_logs_query_enabled:-true}
        #  Log page hits and page faults for the executed queries being logged.
        NEO4j_dbms_logs_query_page__logging__enabled=${NEO4j_dbms_logs_query_page__logging__enabled:-true}
        # Log parameters for the executed queries being logged.NEO4j_dbms_logs_query_page__logging__enabled=${NEO4j_dbms_logs_query_page__logging__enabled:-true}
        NEO4J_dbms_logs_query_parameter__logging__enabled=${NEO4J_dbms_logs_query_parameter__logging__enabled:-true}
        # Path to the query log file.
        NEO4J_dbms_logs_query_path=$NEO4J_HOME/logs/slow_query.log
        # Maximum number of history files for the query log.
        NEO4J_dbms_logs_query_rotation_keep__number=${NEO4J_dbms_logs_query_rotation_keep__number:-10}
        # The file size in bytes at which the query log will auto-rotate.
        NEO4J_dbms_logs_query_rotation_size=${NEO4J_dbms_logs_query_rotation_size:-10000000} # 10MB
        # Logs which runtime that was used to run the query.
        NEO4J_dbms_logs_query_runtime__logging__enabled=${NEO4J_dbms_logs_query_runtime__logging__enabled:-true}
        # If the execution of query takes more time than this threshold, the query is logged - provided query logging is enabled.
        NEO4J_dbms_logs_query_threshold=${NEO4J_dbms_logs_query_threshold:-500ms}
        # Log detailed time information for the executed queries being logged.
        NEO4J_dbms_logs_query_time__logging__enabled=${NEO4J_dbms_logs_query_time__logging__enabled:-true}
    fi

    # TODO: handle in the script more discovery types
    if [ $NEO4J_causal__clustering_discovery__type == "LIST" ]; then
        cloudmap_discover
        NEO4J_causal__clustering_initial__discovery__members=$CLUSTER_IPS
    fi
}

setup_dirs () {
    if [ ! -z "${NEO4J_DATA_ROOT:-}" ]; then
        # Create all needed folders, etc
        mkdir -p $NEO4J_DATA_ROOT

        # make sure subdirs exist
        mkdir -p $NEO4J_DATA_ROOT/data/dbms
        mkdir -p $NEO4J_DATA_ROOT/data/databases
        mkdir -p $NEO4J_DATA_ROOT/data/transactions
        mkdir -p $NEO4J_DATA_ROOT/logs
        mkdir -p $NEO4J_DATA_ROOT/metrics

        chown -R ${userid}:${groupid} $NEO4J_DATA_ROOT

        ln -fsn $NEO4J_DATA_ROOT/data $NEO4J_HOME/data
        ln -fsn $NEO4J_DATA_ROOT/logs $NEO4J_HOME/logs
        ln -fsn $NEO4J_DATA_ROOT/metrics $NEO4J_HOME/metrics

        echo """
su ${userid} ${groupid}

$NEO4J_DATA_ROOT/logs/debug.log {
  rotate 30
}
""" > /tmp/log.rotate

        if [ $NEO4J_QUERY_LOG == "enabled" ]; then
            # rotate slowquery log on each start
            echo """
$NEO4J_DATA_ROOT/logs/slow_query.log {
  rotate 30
}
""" >> /tmp/log.rotate
        fi

        # rotate logs on each start
        logrotate -f /tmp/log.rotate || true
    fi
}

# starting neo4j on "start" parameter
# we need custom parameter, different from the default one "neo4j"
# to avoid default initial user creation (see comments to the "setup_users" function)
if [ "${cmd}" == "start" ]; then
    setup_dirs

    # setup admin and guest userss
    setup_users

    # set needed configuration variables
    configure

    # save configuration variables to the config file
    save_config

    if [ -n "${SNAPSHOT_PATH:-}" ]; then
        if [ "$NEO4J_dbms_mode" == "READ_REPLICA" ]; then 
            # do not fail script if restore from backup failed for READ_REPLICA
            set +e 
        fi
        restore_neo4j
        set -e
    fi

    # Make sure, atleast 10 seconds passed since container start
    # before starting neo4j, because we used to face issue
    # when neo4j binding port to the docker0 network interface
    # (https://github.com/neo4j/neo4j/issues/12221)
    # and sleep seems to help, however, when we restoring from the backup
    # 10 seconds will pass anyway, so calculate sleep time dynamicaly
    sleep_time=$(($script_start_time+10-$(date +%s)))
    if [ $sleep_time -ge 0 ]; then
        echo "Sleeping for ${sleep_time}s before starting neo4j"
        sleep $sleep_time
    fi

    ${exec_cmd} neo4j console
elif [ "${cmd}" == "backup" ]; then
    if [ -z  $BACKUP_FROM ] || [ "$BACKUP_FROM" == "this_instance" ]; then
        INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4/)
        MACS=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
        BACKUP_FROM=$INSTANCE_IP

        # if instance has more then one ip, then neo4j is running in the "awsvpc" mode
        # and we need to point backup tool on the other container, which has secondary IP
        for m in $MACS; do
            IP=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$m/local-ipv4s);

            if [ "$IP" != "$INSTANCE_IP" ]; then
                BACKUP_FROM=$IP
                break;
            fi
        done
    elif [ "$BACKUP_FROM" == "discovery" ] && [ -n "$CLOUDMAP_SERVICE_ID" ] ; then
        BACKUP_FROM=$(cloudmap_discover_instances | awk '{print $1}')
    fi

    backup
    exit 0
else
    ${exec_cmd} "$@"
fi