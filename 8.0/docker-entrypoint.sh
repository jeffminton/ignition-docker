#!/bin/bash
set -eo pipefail
shopt -s nullglob

# Local initialization
INIT_FILE=/usr/local/share/ignition/data/init.properties
CMD=( "$@" )
WRAPPER_OPTIONS=( )
JAVA_OPTIONS=( )

# Init Properties Helper Functions
add_to_init () {
    # The below takes the first argument as the key and indirects to the second argument
    # to assign the value.  It will skip if the value is undefined.
    if [ ! -z ${!2:-} ]; then
        echo "Added Init Setting ${1}=${!2}"
        echo "${1}=${!2}" >> $INIT_FILE
    fi
}

# Gateway Network Init Properties Helper Function
add_gw_to_init () {
    # This function will add any other defined variables (via add_to_init) for a gateway
    # network connection definition.

    declare -A settings
    settings=( [PingRate]=GATEWAY_NETWORK_${1}_PINGRATE
               [Enabled]=GATEWAY_NETWORK_${1}_ENABLED
               [Host]=GATEWAY_NETWORK_${1}_HOST
               )

    # Loop through the settings above and add_to_init
    for key in ${!settings[@]}; do
        value=${settings[$key]}
        if [ ! -z ${!value:-} ]; then
            add_to_init gateway.network.${1}.${key} ${value}
        fi
    done

    # Handle EnableSSL explicitly, default to true if not specified
    enablessl=GATEWAY_NETWORK_${1}_ENABLESSL
    declare "$enablessl=${!enablessl:-true}"
    add_to_init gateway.network.${1}.EnableSSL ${enablessl}

    # If EnableSSL defaulted to true and Port was not specified, default to 8060
    port=GATEWAY_NETWORK_${1}_PORT
    declare "$port=${!port:-8060}"
    add_to_init gateway.network.${1}.Port ${port}
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# usage: perform_commissioning URL START_FLAG
#   ie: perform_commissioning http://localhost:8088/post-step 1
perform_commissioning() {
    local url="$1"

    # Register EULA Acceptance
    local license_accept_payload='{"id":"license","step":"eula","data":{"accept":true}}'
    curl -H "Content-Type: application/json" -d "${license_accept_payload}" ${url} > /dev/null 2>&1

    # Register Authentication Details
    local auth_user="${GATEWAY_ADMIN_USERNAME:=admin}"
    local auth_salt=$(date +%s | sha256sum | head -c 8)
    local auth_pwhash=$(echo -en ${GATEWAY_ADMIN_PASSWORD}${auth_salt} | sha256sum - | cut -c -64)
    local auth_password="[${auth_salt}]${auth_pwhash}"
    local auth_payload='{"id":"authentication","step":"authSetup","data":{"username":"'${auth_user}'","password":"'${auth_password}'"}}'
    curl -H "Content-Type: application/json" -d "${auth_payload}" ${url} > /dev/null 2>&1

    # Register Port Configuration
    local http_port="${GATEWAY_HTTP_PORT:=8088}"
    local https_port="${GATEWAY_HTTPS_PORT:=8043}"
    local use_ssl="${GATEWAY_USESSL:=false}"
    local port_payload='{"id":"connections","step":"connections","data":{"http":'${http_port}',"https":'${https_port}',"useSSL":'${use_ssl}'}}'
    curl -H "Content-Type: application/json" -d "${port_payload}" ${url} > /dev/null 2>&1

    # Finalize
    if [ "$2" = "1" ]; then
        local start_flag="true"
    else
        local start_flag="false"
    fi
    local finalize_payload='{"id":"finished","data":{"start":'${start_flag}'}}'
    curl -H "Content-Type: application/json" -d "${finalize_payload}" ${url} > /dev/null 2>&1
}

# usage: health_check PHASE_DESC DELAY_SECS
#   ie: health_check "Gateway Commissioning" 60
health_check() {
    local phase="$1"
    local delay=$2

    # Wait for a short period for the commissioning servlet to come alive
    for ((i=${delay};i>0;i--)); do
        if curl -f http://localhost:8088/StatusPing 2>&1 | grep -c RUNNING > /dev/null; then   
            break
        fi
        sleep 1
    done
    if [ "$i" -le 0 ]; then
        echo >&2 "Failed to detect RUNNING status during ${phase} after ${delay} delay."
        exit 1
    fi
}

# usage stop_process PID
#   ie: stop_process 123
stop_process() {
    local pid="$1"

    echo 'Shutting down interim provisioning gateway...'
    if ! kill -s TERM "$pid" || ! wait "$pid"; then
        echo >&2 'Ignition initialization process failed.'
        exit 1
    fi
}

# Collect additional arguments if we're running the gateway
if [ "$1" = './ignition-gateway' ]; then
    # Examine memory constraints and apply to Java arguments
    if [ ! -z ${GATEWAY_INIT_MEMORY:-} ]; then
        if [ ${GATEWAY_INIT_MEMORY} -ge 256 2> /dev/null ]; then
            WRAPPER_OPTIONS+=(
                "wrapper.java.initmemory=${GATEWAY_INIT_MEMORY}"
                )
        else
            echo >&2 "Invalid minimum memory specification, must be integer in MB: ${GATEWAY_INIT_MEMORY}"
            exit 1
        fi    
    fi

    if [ ! -z ${GATEWAY_MAX_MEMORY:-} ]; then
        if [ ${GATEWAY_MAX_MEMORY} -ge 512 2> /dev/null ]; then
            WRAPPER_OPTIONS+=(
                "wrapper.java.maxmemory=${GATEWAY_MAX_MEMORY}"
            )
        else
            echo >&2 "Invalid max memory specification, must be integer in MB: ${GATEWAY_MAX_MEMORY}"
            exit 1
        fi
    fi

    if [ ${GATEWAY_INIT_MEMORY:-256} -gt ${GATEWAY_MAX_MEMORY:-512} ]; then
        echo >&2 "Invalid memory specification, min (${GATEWAY_MIN_MEMORY}) must be less than max (${GATEWAY_MAX_MEMORY})"
        exit 1
    fi

    # Combine CMD array with wrapper and explicit java options
    if [ ! -z ${JAVA_OPTIONS:-} ]; then
        JAVA_OPTIONS=( "--" "${JAVA_OPTIONS[@]}" )
    fi
    CMD+=(
        "${WRAPPER_OPTIONS[@]}"
        "${JAVA_OPTIONS[@]}"
    )
fi

# Check for no Docker Init Complete file
if [ "$1" = './ignition-gateway' -a ! -f "/usr/local/share/ignition/data/.docker-init-complete" ]; then
    # Check Prerequisites
    file_env 'GATEWAY_ADMIN_PASSWORD'
    if [ -z "$GATEWAY_ADMIN_PASSWORD" -a -z "$GATEWAY_RANDOM_ADMIN_PASSWORD" ]; then
        echo >&2 'ERROR: Gateway is not initialized and no password option is specified '
        echo >&2 '  You need to specify either GATEWAY_ADMIN_PASSWORD or GATEWAY_RANDOM_ADMIN_PASSWORD'
        exit 1
    fi

    # Mark Initialization Complete
    touch /usr/local/share/ignition/data/.docker-init-complete

    # Provision the init.properties file if we've got the environment variables for it
    rm -f /var/lib/ignition/data/init.properties
    add_to_init "SystemName" GATEWAY_SYSTEM_NAME
    add_to_init "UseSSL" GATEWAY_USESSL

    # Look for declared HOST variables and add the other associated ones via add_gw_to_init
    looper=GATEWAY_NETWORK_${i:=0}_HOST
    while [ ! -z ${!looper:-} ]; do
        # Add all available env parameters for this host to the init file
        add_gw_to_init $i
        # Index to the next HOST variable
        looper=GATEWAY_NETWORK_$((++i))_HOST
    done

    # Enable Gateway Network Certificate Auto Accept if Declared
    if [ "${GATEWAY_NETWORK_AUTOACCEPT_DELAY}" -gt 0 ] 2>/dev/null; then
        accept-gwnetwork.sh ${GATEWAY_NETWORK_AUTOACCEPT_DELAY} &
    fi

    # Perform some staging for the rest of the provisioning process
    if [ ! -z "$GATEWAY_RANDOM_ADMIN_PASSWORD" ]; then
        export GATEWAY_ADMIN_PASSWORD="$(pwgen -1 32)"
    fi
    if [ -f "/restore.gwbk" ]; then
        export GATEWAY_RESTORE_REQUIRED="1"
    else
        export GATEWAY_RESTORE_REQUIRED="0"
    fi

    # Initialize Startup Gateway before Attempting Restore
    echo "Provisioning will be logged here: ${IGNITION_INSTALL_LOCATION}/logs/provisioning.log"
    "${CMD[@]}" > /usr/local/share/ignition/logs/provisioning.log 2>&1 &
    pid="$!"

    echo "Waiting for commissioning servlet to become active..."
    health_check "Commissioning Phase" 10

    echo "Performing commissioning actions..."
    perform_commissioning "http://localhost:8088/post-step" ${GATEWAY_RESTORE_REQUIRED}
    echo "  GATEWAY_ADMIN_USERNAME: ${GATEWAY_ADMIN_USERNAME}"
    if [ ! -z "$GATEWAY_RANDOM_ADMIN_PASSWORD" ]; then echo "  GATEWAY_RANDOM_ADMIN_PASSWORD: ${GATEWAY_ADMIN_PASSWORD}"; fi
    echo "  GATEWAY_HTTP_PORT: ${GATEWAY_HTTP_PORT}"
    echo "  GATEWAY_HTTPS_PORT: ${GATEWAY_HTTPS_PORT}"
    # echo "  GATEWAY_USESSL: ${GATEWAY_USESSL}"

    # The restore will prepare the backup to be restored on the next gateway startup
    if [ -f "/restore.gwbk" ]; then
        sleep 5
        echo "Commissioning completed, awaiting initial gateway startup prior to restore..."
        health_check "Startup" ${IGNITION_STARTUP_DELAY:=60}

        echo 'Restoring Gateway Backup...'
        printf '\n' | ./gwcmd.sh --restore /restore.gwbk -y
        stop_process $pid
    else
        stop_process $pid
    fi

    echo 'Starting Ignition Gateway...'
fi

exec "${CMD[@]}"