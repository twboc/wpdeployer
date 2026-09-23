#!/bin/bash

# export CONF_GROUP="default"

# export HOST=""
export HOST_www=true                        # true|false
export HOST_onlySubdomains=false            # true|false
export HOST_subdomains=()                   #('subdomain1' 'subdomain2')

# Volume paths are derived by the deployer from the config filename:
#   volumes/<config name>/wordpress  and  volumes/<config name>/mariadb
# Do not set WP_volume / DB_volume / WP_volumePath / DB_volumePath here.

export WP_container_name="wordpress"
export WP_image="wordpress"
export WP_portOut='81'
export WP_portIn='80'
export WP_debug=null

export DB_container_name="mariadb"
export DB_image="mariadb"
export DB_portOut='3301'
export DB_portIn='3306'
# export DB_pass=""
# export DB_name=""

export LOGS_enabled=false                   # true|false
export LOGS_retentionDays=7
export LOGS_maxSizeMB=500
export LOGS_slowQueryTime=0                 # seconds, 0 disables the slow query log
export WP_debugLog=false                    # true|false
