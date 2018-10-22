#!/bin/bash

export HOST_www=false                       # true|false
export HOST_onlySubdomains=true             # true|false
export HOST_subdomains=()                   #('subdomain1' 'subdomain2')

export WP_name="woocommerce"
export WP_volume="$rootDir/volumes/$domainFile/woocommerce"
export WP_volumePath="$WP_volume:/var/www/html"
export WP_portOut='81'
export WP_portIn='80'

export DB_name="mariadb"
export DB_volume="$rootDir/volumes/$domainFile/mariadb"
export DB_volumePath="$DB_volume:/var/lib/mysql"
export DB_portOut='3301'
export DB_portIn='3306'
