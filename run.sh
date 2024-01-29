#!/bin/bash
rootDir=$(pwd);

# source get utils
. $rootDir/deployer/scripts/util.sh

# source the database password variable
. $rootDir/deployer/DB_connection.sh --source-only

CONFIGS_PATH=$rootDir/configs/
RESTART_ALL="RESTART_ALL"

util::prevent_subshell
util::check_dependencies
util::create_directory $rootDir/volumes

files=($CONFIGS_PATH*)
options=($(util::build_options "${files[@]}"))

echo "Choose Option - All, group, domain."

option=$(util::select_option "${options[@]}" )

action::execute_option $option

action::set_database_pass


action::iterate_configs(){
    echo "Iterating configs in: $1"
    # start websites example $1 => $rootDir/configs/*
    for file in "$1"*
    do
        if [[ -f $file ]]; then


            if [[ $option == $RESTART_ALL ]]; then
                action::process_config $file
            else

                FILE=$(basename $file .sh)

                # if [[ $FILE == *$option"_"* ]]; then
                #     echo "Restart selected config: $FILE"
                #     action::process_config $file
                # fi

            fi
        
        fi
    done

}


action::iterate_configs $CONFIGS_PATH

docker ps

