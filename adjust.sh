#!/bin/bash

cd configs
pwd
sed -i "s/WP_name/WP_container_name/g" *
sed -i "s/DB_name/DB_container_name/g" *

cd ../

