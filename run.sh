#!/bin/bash
rootDir=$(pwd);

. $rootDir/deployer/scripts/utils.sh

preventSubshell

installPackageIfNotExists "curl"
installPackageIfNotExists "docker"
installPackageIfNotExists "docker-compose"

mkdir -p $rootDir/volumes

for file in $rootDir/configs/*
do
    if [[ -f $file ]]; then

    domain=$(basename $file .sh)

    . $rootDir/configs/$domain.sh --source-only

    mkdir -p $DB_volume
    mkdir -p $WP_volume

    mkdir -p "$rootDir/domains/$domain"
    rm -rf $rootDir/domains/$domain/docker-compose.yml;

    echo $WP_name
    echo $WP_volume
    echo $WP_volumePath
    echo $WP_port

    echo $DB_name
    echo $DB_volume
    echo $DB_volumePath
    echo $DB_port

    export WP_name
    export WP_volume
    export WP_volumePath
    export WP_port

    export DB_name
    export DB_volume
    export DB_volumePath
    export DB_port

    envsubst < "$rootDir/deployer/template.yml" > "$rootDir/domains/$domain/docker-compose.yml";

    sudo docker-compose -f "$rootDir/domains/$domain/docker-compose.yml" up

    fi
done