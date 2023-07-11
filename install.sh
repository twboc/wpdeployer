#!/bin/bash
rootDir=$(pwd);

# source get utils
. $rootDir/deployer/scripts/util.sh

util::prepare_restart_script
util::create_configs_directory
util::copy_example_config

util::install_docker

return 0
