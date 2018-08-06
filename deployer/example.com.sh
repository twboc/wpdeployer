#!/bin/bash

export WP_name="woocommerce1"
export WP_volume="$rootDir/volumes/$domain/woocommerce"
export WP_volumePath="$WP_volume:/var/www/html"
export WP_portOut='80'
export WP_portIn='80'

export DB_name="woo_mariadb1"
export DB_volume="$rootDir/volumes/$domain/mariadb"
export DB_volumePath="$DB_volume:/var/lib/mysql"
export DB_portOut='3301'
export DB_portIn='3306'

