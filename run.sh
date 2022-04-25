#!/bin/bash
rootDir=$(pwd);

# source get utils
. $rootDir/deployer/scripts/util.sh

# source the database password variable
. $rootDir/deployer/DBPass.sh --source-only

util::prevent_subshell
util::clear_docker_containers
util::check_dependencies
util::create_directory $rootDir/volumes

action::run_letsencrypt_containers
action::set_database_pass

# start websites
for file in $rootDir/configs/*
do
    if [[ -f $file ]]; then
    
        util::clear_domain_file_vars
        export DOMAIN_FILE=$(basename $file .sh)
        . $rootDir/configs/$DOMAIN_FILE.sh --source-only
        action::check_host_variable
        export domain=$HOST
        util::create_directory $DB_volume
        util::create_directory $WP_volume
        util::create_directory "$rootDir/domains/$DOMAIN_FILE"
        util::delete $rootDir/domains/$DOMAIN_FILE/docker-compose.yml
        action::resolve_subdomains HOST_domainsDeclaration
        task::create_containers
    
    fi
done

action::run_letsencrypt_containers
