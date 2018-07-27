#!/bin/bash

export WP_name="woocommerce1"
export WP_volume="$rootDir/volumes/$domain/woocommerce"
export WP_volumePath="$DB_volume:/var/www/html"
export WP_PORT='81:80'

export DB_name="woo_mariadb1"
export DB_volume="$rootDir/volumes/$domain/mariadb"
export DB_volumePath="$WP_volume:/var/lib/mysql"
export DB_port='3301:3306'

