#!/bin/bash
rootDir=$(pwd);

. $rootDir/deployer/scripts/utils.sh

preventSubshell

sudo docker stop $(sudo docker ps -a -q)
sudo docker rm $(sudo docker ps -a -q)

installPackageIfNotExists "curl"
installPackageIfNotExists "docker"
installPackageIfNotExists "docker-compose"

mkdir -p $rootDir/volumes

# source the database password variable
. $rootDir/deployer/DBPass.sh --source-only
export DBPass;

if [ -z "$DBPass" ]; then 
    echo "DBPass is unset"; 
    echo "Please set the DBPass variable in $rootDir/deployer/DBPass.sh file";
    return;
else 
    echo "DBPass is set to '$DBPass'"; 
fi

# create separate network
sudo docker network create nginx-proxy

# run proxy handlers
envsubst < "$rootDir/deployer/nginx/template.yml" > "$rootDir/deployer/nginx/docker-compose.yml";
sudo docker-compose -f "$rootDir/deployer/nginx/docker-compose.yml" up -d



# start websites
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

    fi
done