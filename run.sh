#!/bin/bash
rootDir=$(pwd);

. $rootDir/deployer/scripts/utils.sh

resolveSubdomains(){
    return_=0 

    if [ -z "$HOST_www" ]; then 
        echo "Variable $HOST_www is not set" 1>&2
        echo "Setting $HOST_www to: true" 1>&2
        HOST_www=true
        echo "Including the www subdomain" 1>&2
        HOST_subdomains+=('www')
    else 
        echo "WWW subdomain is included" 1>&2
        if [ "$HOST_www" = true ] ; then
            echo "Including the www subdomain" 1>&2
            HOST_subdomains+=('www')
        fi
    fi

    if [ "$HOST_onlySubdomains" = true ]; then
        echo "Omitting SLD without subdomain" 1>&2
    else
        echo "Adding SLD without subdomain" 1>&2
        HOST_domains+=($domain)
    fi

    for subdomain in "${HOST_subdomains[@]}"
    do
        echo "Adding subdomain $subdomain.$domain to HOST_domains" 1>&2
        HOST_domains+=("$subdomain.$domain")
    done

    if [ ${#HOST_domains[@]} -eq 0 ]; then
        echo "" 1>&2
        echo "!!!!! ERROR !!!!!" 1>&2
        echo "" 1>&2
        echo "Configuration did not create a list of domains" 1>&2
        echo "Domain $domain configuration file declares no domains for HOST_domainsDeclaration variable" 1>&2
        echo "Please check your config if HOST_www, HOST_onlySubdomains, HOST_subdomains variables" 1>&2
        echo "HOST_onlySubdomains set to true and empty HOST_subdomains creates no variables" 1>&2
        echo "" 1>&2
        local return_=1;
    else
        echo "Cofiguration created a list of domains" 1>&2
        HOST_domainsDeclaration=$(printf ", %s" "${HOST_domains[@]}")
        HOST_domainsDeclaration=${HOST_domainsDeclaration:1}
        echo "HOST_domainsDeclaration: " 1>&2
        echo $HOST_domainsDeclaration 1>&2
        local return_=0;
    fi

    echo "$return_"

}

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

    export domainFile=$(basename $file .sh)
    
    #get domain without subdomains
    domainArr=(${domainFile//./ })
    export domain=${domainArr[-2]}.${domainArr[-1]}
    
    export HOST_domains=()
    export HOST_subdomains=()
    export HOST_domainsDeclaration=""

    . $rootDir/configs/$domainFile.sh --source-only

    mkdir -p $DB_volume
    mkdir -p $WP_volume

    mkdir -p "$rootDir/domains/$domainFile"
    rm -rf $rootDir/domains/$domainFile/docker-compose.yml;

    if [ $(resolveSubdomains) -eq 0 ]; then
        envsubst < "$rootDir/deployer/template.yml" > "$rootDir/domains/$domainFile/docker-compose.yml";
        sudo docker-compose -f "$rootDir/domains/$domainFile/docker-compose.yml" up -d
    else
        echo ""
        echo "Domains and subdomains not created for $domainFile"
        echo "Omitting container configuration for $(basename $file)"
    fi
    
    fi
done