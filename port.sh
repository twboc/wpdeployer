#!/bin/bash
wp_prefix="export WP_portOut='"
db_prefix="export DB_portOut='"
suffix="'"

wp_ports=$(cat ./configs/* | grep WP_portOut= | sed -e "s/^$wp_prefix//" -e "s/$suffix$//" | sort -n )
db_ports=$(cat ./configs/* | grep DB_portOut= | sed -e "s/^$db_prefix//" -e "s/$suffix$//" | sort -n )

echo $wp_ports
echo $db_ports