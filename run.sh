#!/bin/bash
rootDir=$(pwd);

. $rootDir/deployer/scripts/utils.sh

preventSubshell

installPackageIfNotExists "curl"
installPackageIfNotExists "docker"
installPackageIfNotExists "docker-compose"

mkdir -p $rootDir/volumes

# start up the nginx container
rm -rf $rootDir/deployer/nginx/docker-compose.yml;

mkdir -p $rootDir/deployer/nginx/volume/
mkdir -p $rootDir/deployer/nginx/volume/sites-available
mkdir -p $rootDir/deployer/nginx/volume/sites-enabled



for file in $rootDir/configs/*
do
    if [[ -f $file ]]; then

    domain=$(basename $file .sh)
    export domain

    . $rootDir/configs/$domain.sh --source-only

    mkdir -p $DB_volume
    mkdir -p $WP_volume

    mkdir -p "$rootDir/domains/$domain"
    rm -rf $rootDir/domains/$domain/docker-compose.yml;

    envsubst < "$rootDir/deployer/template.yml" > "$rootDir/domains/$domain/docker-compose.yml";

    sudo docker-compose -f "$rootDir/domains/$domain/docker-compose.yml" up -d


    

    envsubst '$domain $WP_portOut' < "$rootDir/deployer/nginx/serverTemplate" > "$rootDir/deployer/nginx/volume/sites-available/$domain";

    ln -s $rootDir/deployer/nginx/volume/sites-available/$domain $rootDir/deployer/nginx/volume/sites-enabled/$domain



    fi
done

NX_volume="$rootDir/deployer/nginx/volume/"
NX_volumePath=$NX_volume":/etc/nginx/:ro"
NX_volumeSA=$rootDir/deployer/nginx/volume/sites-available":/etc/nginx/sites-available:ro"
NX_volumeSE=$rootDir/deployer/nginx/volume/sites-enabled":/etc/nginx/sites-enabled:ro"

export NX_volume;
export NX_volumePath;
export NX_volumeSA;
export NX_volumeSE;

cp $rootDir/deployer/nginx/nginx.conf $rootDir/deployer/nginx/volume/nginx.conf

envsubst < "$rootDir/deployer/nginx/template.yml" > "$rootDir/deployer/nginx/docker-compose.yml";
sudo docker-compose -f "$rootDir/deployer/nginx/docker-compose.yml" up -d