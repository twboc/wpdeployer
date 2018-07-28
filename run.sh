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

    envsubst < "$rootDir/deployer/template.yml" > "$rootDir/domains/$domain/docker-compose.yml";

    sudo docker-compose -f "$rootDir/domains/$domain/docker-compose.yml" up -d

    fi
done

# start up the nginx container
rm -rf $rootDir/deployer/nginx/docker-compose.yml;
mkdir -p $rootDir/deployer/nginx/volume/
NX_volume="$rootDir/deployer/nginx/volume/"
NX_volumePath=$NX_volume":/etc/nginx/:ro"
export NX_volume;
export NX_volumePath;

envsubst < "$rootDir/deployer/nginx/template.yml" > "$rootDir/deployer/nginx/docker-compose.yml";
sudo docker-compose -f "$rootDir/deployer/nginx/docker-compose.yml" up -d