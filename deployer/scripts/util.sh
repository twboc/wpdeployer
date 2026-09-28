#!/bin/bash

util::prevent_subshell(){
  if [[ $_ != $0 ]]
  then
    echo "Script is being sourced"
  else
    echo "Script is a subshell - please run the script by invoking . script.sh command";
    exit 1;
  fi
}

util::prepare_restart_script(){
  AUTOSTART="wpdeployer_autostart"
  AUTOSTART_PATH="/etc/init.d/$AUTOSTART.sh"

  rm -rf $AUTOSTART_PATH || true
  cp "./deployer/scripts/$AUTOSTART.sh" $AUTOSTART_PATH
  chmod +x $AUTOSTART_PATH

  touch /var/spool/cron/crontabs/root
  crontab -l | { cat; echo "@reboot $AUTOSTART_PATH"; } | crontab -
}

util::install_docker(){
  sudo apt-get -y update
  sudo apt-get -y install \
      apt-transport-https \
      ca-certificates \
      curl \
      gnupg-agent \
      software-properties-common
      
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo apt-key -y fingerprint 0EBFCD88
  sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
  sudo apt-get -y update
  sudo apt-get -y install docker-ce docker-ce-cli containerd.io
  sudo apt-get -y install docker-ce=<VERSION_STRING> docker-ce-cli=<VERSION_STRING> containerd.io
  sudo curl -L "https://github.com/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
}

util::create_configs_directory(){
  mkdir $rootDir/configs
}

util::copy_example_config(){
  cp $rootDir/deployer/example.com.sh $rootDir/configs/example.com.sh
}

util::clear_docker_containers(){
  sudo docker stop $(sudo docker ps -a -q)
  sudo docker rm $(sudo docker ps -a -q)
}

util::clear_docker_containers_containing(){
  echo "Docker clearing containers containing: $1"
  sudo docker ps | grep $1 | awk '{ print $1 }' | docker stop $(</dev/stdin)
}

util::check_dependencies(){
  installPackageIfNotExists "curl"
  installPackageIfNotExists "docker"
  util::resolve_compose
}

util::resolve_compose(){
  if docker compose version >/dev/null 2>&1; then
    export COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    export COMPOSE_CMD="docker-compose"
    echo "!!! Falling back to docker-compose v1, which crashes with KeyError: 'ContainerConfig'"
    echo "!!! when recreating containers on current Docker Engine. Install the compose v2 plugin."
  else
    echo "!!! Neither 'docker compose' nor 'docker-compose' is available"
    return 1
  fi
  echo "Compose command: $COMPOSE_CMD"
}

util::create_directory(){
  if [ -z "$1" ]; then
    echo "!!! create_directory called with an empty path - refusing"
    return 1
  fi
  echo "Creating directory: $1"
  mkdir -p "$1"
}

util::delete(){
  if [ -z "$1" ]; then
    echo "!!! delete called with an empty path - refusing"
    return 1
  fi
  echo "Deleting: $1"
  rm -rf "$1"
}

util::clear_domain_file_vars(){
  unset HOST HOST_www HOST_onlySubdomains
  unset WP_volume WP_volumePath DB_volume DB_volumePath
  unset LOGS_enabled LOGS_retentionDays LOGS_maxSizeMB LOGS_slowQueryTime
  unset LOGS_dir WP_debugLog WP_configExtra WP_apacheConfPath
  unset DB_confFile DB_confPath
  unset WP_maxWorkers WP_phpMemory WP_opcacheMB WP_mpmConfFile WP_mpmConfPath WP_phpConfFile WP_phpConfPath
  unset WP_container_name WP_image WP_portOut WP_portIn WP_debug
  unset DB_container_name DB_image DB_portOut DB_portIn
  unset DB_pass DB_name DB_user DB_host DB_mode DB_group
  export HOST_domains=()
  export HOST_subdomains=()
  export HOST_domainsDeclaration=""
}

util::build_options() {
    files=("$@")
    base=($RESTART_ALL $CANCEL)
    groups=()
    configs=()
    
    for file in "${files[@]}";
    do
        FILE=$(basename $file .sh)
        configs=(${configs[@]} "CONFIG:$FILE")
        if [[ $FILE == *"_"* ]]; then
            FILE_ARR=(${FILE//_/ })
            groups=(${groups[@]} "GROUP:$FILE_ARR")
        fi
    done

    unique_groups=($(printf "%s\n" "${groups[@]}" | sort -u))

    dbgroups=()
    for dbg in "$rootDir"/db_groups/*.sh; do
        [ -f "$dbg" ] && dbgroups=(${dbgroups[@]} "DBGROUP:$(basename "$dbg" .sh)")
    done

    local all=( "${base[@]}" "${dbgroups[@]}" "${unique_groups[@]}" "${configs[@]}" )
    echo ${all[@]}
}

util::select_option(){
    local options=("$@")
    selected_option=""
    select option in "${options[@]}";
    do
        selected_option=$option
        break;
    done
    echo $selected_option
}

action::run_base(){
  echo "Running - nginx and acme companion"
  cd "$rootDir/deployer/base"
  $COMPOSE_CMD up -d
  cd "$rootDir"
}

action::run_logger(){
  echo "Running - log collector"
  cd "$rootDir/deployer/logger"
  WPDEPLOYER_VOLUMES="$rootDir/volumes" $COMPOSE_CMD up -d
  cd "$rootDir"
}

dbgroup::load(){
  unset DBG_name DBG_image DBG_rootPass DBG_maxSites DBG_bufferPoolMB DBG_maxConnections
  if [[ ! "$1" =~ ^[a-z0-9]+$ ]]; then
    echo "!!! Invalid DB group name '$1' - use lowercase letters and digits"
    return 1
  fi
  if [ ! -f "$rootDir/db_groups/$1.sh" ]; then
    echo "!!! DB group file not found: $rootDir/db_groups/$1.sh"
    return 1
  fi
  . "$rootDir/db_groups/$1.sh"
  export DBG_name=$1
  [ -n "${DBG_maxSites:-}" ] || DBG_maxSites=20
  [ -n "${DBG_bufferPoolMB:-}" ] || DBG_bufferPoolMB=1024
  [ -n "${DBG_maxConnections:-}" ] || DBG_maxConnections=300
  if [ -z "${DBG_image:-}" ] || [ -z "${DBG_rootPass:-}" ]; then
    echo "!!! DBG_image and DBG_rootPass must be set in db_groups/$1.sh"
    return 1
  fi
  export DBG_image DBG_rootPass DBG_maxSites DBG_bufferPoolMB DBG_maxConnections
  export DBG_container="wpdb-$1"
  export DBG_dataPath="$rootDir/volumes_shared/$1/mariadb"
  export DBG_confFile="$rootDir/domains_shared/$1/mariadb.cnf"
  export DBG_composeFile="$rootDir/domains_shared/$1/docker-compose.yml"
}

dbgroup::sql(){
  docker exec -i -e MYSQL_PWD="$DBG_rootPass" "$DBG_container" mariadb -uroot -N -B "$@"
}

dbgroup::wait_ready(){
  for _i in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$DBG_container" 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  echo "!!! $DBG_container did not become healthy"
  return 1
}

dbgroup::site_count(){
  grep -l "^export DB_group=$1\$" "$rootDir"/configs/*.sh 2>/dev/null | xargs -r grep -l '^export DB_mode=shared$' | wc -l
}

action::run_db_group(){
  dbgroup::load "$1" || return 1
  echo "Running - shared DB group $DBG_name ($DBG_container)"
  util::create_directory "$DBG_dataPath"
  util::create_directory "$(dirname "$DBG_confFile")"
  {
    echo "[mysqld]"
    echo "innodb_buffer_pool_size = ${DBG_bufferPoolMB}M"
    echo "max_connections = $DBG_maxConnections"
  } > "$DBG_confFile"
  envsubst < "$rootDir/deployer/db_group/template.yml" > "$DBG_composeFile"
  sudo $COMPOSE_CMD -p "wpdb-$DBG_name" -f "$DBG_composeFile" up -d || return 1
  dbgroup::wait_ready
}

action::run_all_db_groups(){
  for _dbg in "$rootDir"/db_groups/*.sh; do
    [ -f "$_dbg" ] && action::run_db_group "$(basename "$_dbg" .sh)"
  done
  return 0
}

action::resolve_db_mode(){
  [ -n "${DB_mode:-}" ] || DB_mode=dedicated
  export DB_mode
  [ "$DB_mode" = dedicated ] && return 0
  if [ "$DB_mode" != shared ]; then
    echo "!!! $DOMAIN_FILE: DB_mode must be dedicated or shared, got '$DB_mode'"
    return 1
  fi
  dbgroup::load "${DB_group:-}" || return 1
  export DB_group
  if [ "${DB_host:-}" != "$DBG_container" ]; then
    echo "!!! $DOMAIN_FILE: DB_host must be $DBG_container for DB_group=$DB_group"
    return 1
  fi
  if [[ ! "${DB_name:-}" =~ ^[A-Za-z0-9_]{1,64}$ ]] || [[ ! "${DB_user:-}" =~ ^[A-Za-z0-9_]{1,80}$ ]] || [[ ! "${DB_pass:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "!!! $DOMAIN_FILE: shared mode needs DB_name/DB_user (letters, digits, _) and DB_pass (16+ letters/digits)"
    return 1
  fi
  if [ "$DB_name" = mysql ] || [ "$DB_user" = root ]; then
    echo "!!! $DOMAIN_FILE: shared mode cannot use DB_name=mysql or DB_user=root"
    return 1
  fi
  _count=$(dbgroup::site_count "$DB_group")
  if [ "$_count" -gt "$DBG_maxSites" ]; then
    echo "!!! WARNING: DB group $DB_group has $_count sites, limit is $DBG_maxSites - move sites to another group"
  fi
}

action::provision_shared_db(){
  [ "$DB_mode" = shared ] || return 0
  if [ "$(docker inspect -f '{{.State.Running}}' "$DBG_container" 2>/dev/null)" != true ]; then
    action::run_db_group "$DB_group" || return 1
  fi
  dbgroup::wait_ready || return 1
  _maxconn=$(( WP_maxWorkers + 5 ))
  dbgroup::sql <<SQL || { echo "!!! Could not provision database $DB_name in $DBG_container"; return 1; }
CREATE DATABASE IF NOT EXISTS \`$DB_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_user'@'%' IDENTIFIED BY '$DB_pass';
ALTER USER '$DB_user'@'%' IDENTIFIED BY '$DB_pass' WITH MAX_USER_CONNECTIONS $_maxconn;
GRANT ALL PRIVILEGES ON \`$DB_name\`.* TO '$DB_user'@'%';
SQL
  echo "Provisioned database $DB_name for $DOMAIN_FILE in $DBG_container"
}

action::check_host_variable(){
  if [ -z "$HOST" ];
    then
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
      echo "!!!";
      echo "!!! $DOMAIN_FILE NO HOST VARIABLE IN CONFIG";
      echo "!!!";
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
      return 1
    else
      echo "HOST is set to '$HOST'";
  fi
}

action::execute_option(){
    echo "Executing Option: $option"

    if [[ $1 == $RESTART_ALL ]]; then
        util::clear_docker_containers
        action::run_base
        action::run_all_db_groups
    elif [[ $1 == "DBGROUP:"* ]]; then
        action::run_db_group "${1#DBGROUP:}"
    else

        if [[ $option == "GROUP:"* ]]; then
          util::clear_docker_containers_containing ${option/"GROUP:"/}"_"
        fi

        if [[ $option == "CONFIG:"* ]]; then
          util::clear_docker_containers_containing ${option/"CONFIG:"/}
        fi

    fi
}

action::resolve_subdomains(){

    if [ -z "$HOST_www" ]; then 
        echo "Variable $HOST_www is not set" 1>&2
        echo "Setting $HOST_www to: true" 1>&2
        echo "Including the www subdomain" 1>&2
        HOST_www=true
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
    else
        echo "Cofiguration created a list of domains" 1>&2
        HOST_domainsDeclaration=$(printf ",%s" "${HOST_domains[@]}")
        HOST_domainsDeclaration=${HOST_domainsDeclaration:1}
    fi

    export HOST_domainsDeclaration
    printf -v "$1" '%s' "$HOST_domainsDeclaration"

}


action::resolve_volume_paths(){
  export WP_volume="$rootDir/volumes/$DOMAIN_FILE/wordpress"
  export DB_volume="$rootDir/volumes/$DOMAIN_FILE/mariadb"
  export WP_volumePath="$WP_volume:/var/www/html"
  export DB_volumePath="$DB_volume:/var/lib/mysql"
}

action::resolve_log_settings(){
  export LOGS_dir="$rootDir/volumes/$DOMAIN_FILE/logs"
  export WP_apacheConfPath="$rootDir/deployer/wordpress/deny-logs.conf:/etc/apache2/conf-enabled/zz-wpdeployer-deny-logs.conf:ro"

  [ -n "${LOGS_enabled:-}" ] || LOGS_enabled=false
  [ -n "${LOGS_retentionDays:-}" ] || LOGS_retentionDays=7
  [ -n "${LOGS_maxSizeMB:-}" ] || LOGS_maxSizeMB=500
  [ -n "${LOGS_slowQueryTime:-}" ] || LOGS_slowQueryTime=0
  [ -n "${WP_debugLog:-}" ] || WP_debugLog=false
  export LOGS_enabled LOGS_retentionDays LOGS_maxSizeMB LOGS_slowQueryTime WP_debugLog

  export DB_confFile="$rootDir/domains/$DOMAIN_FILE/mariadb.cnf"
  export DB_confPath="$DB_confFile:/etc/mysql/conf.d/zz-wpdeployer.cnf:ro"

  if [ "$WP_debugLog" = true ]; then
    WP_debug=1
    export WP_configExtra="define('WP_DEBUG_LOG', true); define('WP_DEBUG_DISPLAY', false); @ini_set('display_errors', 0);"
  else
    export WP_configExtra=""
  fi

  case "$(printf '%s' "${WP_debug:-}" | tr '[:upper:]' '[:lower:]')" in
    ""|null|false|0|no|off) WP_debug="" ;;
    *) WP_debug=1 ;;
  esac
  export WP_debug
}

action::resolve_wp_tuning(){
  [ -n "${WP_maxWorkers:-}" ] || WP_maxWorkers=10
  [ -n "${WP_phpMemory:-}" ] || WP_phpMemory=128M
  [ -n "${WP_opcacheMB:-}" ] || WP_opcacheMB=64
  export WP_maxWorkers WP_phpMemory WP_opcacheMB
  export WP_mpmConfFile="$rootDir/domains/$DOMAIN_FILE/apache-mpm.conf"
  export WP_mpmConfPath="$WP_mpmConfFile:/etc/apache2/conf-enabled/zz-wpdeployer-mpm.conf:ro"
  export WP_phpConfFile="$rootDir/domains/$DOMAIN_FILE/php.ini"
  export WP_phpConfPath="$WP_phpConfFile:/usr/local/etc/php/conf.d/zz-wpdeployer.ini:ro"
}

action::write_wp_conf(){
  [ -n "${WP_mpmConfFile:-}" ] || return 0
  _spare=$(( WP_maxWorkers < 3 ? WP_maxWorkers : 3 ))
  {
    echo "<IfModule mpm_prefork_module>"
    echo "    StartServers 1"
    echo "    MinSpareServers 1"
    echo "    MaxSpareServers $_spare"
    echo "    MaxRequestWorkers $WP_maxWorkers"
    echo "    MaxConnectionsPerChild 1000"
    echo "</IfModule>"
    echo "KeepAliveTimeout 2"
  } > "$WP_mpmConfFile"
  {
    echo "memory_limit = $WP_phpMemory"
    echo "opcache.memory_consumption = $WP_opcacheMB"
  } > "$WP_phpConfFile"
}

action::write_db_conf(){
  [ -n "${DB_confFile:-}" ] || return 0
  {
    echo "[mysqld]"
    if [ "$LOGS_enabled" = true ] && [ "$LOGS_slowQueryTime" != 0 ]; then
      echo "slow_query_log = 1"
      echo "slow_query_log_file = /var/lib/mysql/slow.log"
      echo "long_query_time = $LOGS_slowQueryTime"
    fi
  } > "$DB_confFile"
}

action::write_log_retention(){
  [ -d "$LOGS_dir" ] || return 0
  printf 'days=%s\nmaxmb=%s\n' "$LOGS_retentionDays" "$LOGS_maxSizeMB" > "$LOGS_dir/.retention"
}

task::create_containers(){
  if [ -z "$HOST_domainsDeclaration"  ]; then
      echo ""
      echo "Domains and subdomains not created for $DOMAIN_FILE"
      echo "Omitting container configuration for $(basename $file)"
  else
      _template="$rootDir/deployer/template.yml"
      [ "$DB_mode" = shared ] && _template="$rootDir/deployer/template_shared.yml"
      envsubst < "$_template" > "$rootDir/domains/$DOMAIN_FILE/docker-compose.yml";
      sudo $COMPOSE_CMD -f "$rootDir/domains/$DOMAIN_FILE/docker-compose.yml" up -d --remove-orphans
  fi
}

action::set_database_pass(){
  if [ -z "$DB_pass" ]; then 
    echo "DB_pass is unset"; 
    echo "Please set the DB_pass variable in $rootDir/deployer/DB_connection.sh file";
    return;
  else 
    echo "Default DB_pass is set in $rootDir/deployer/DB_connection.sh"; 
  fi

  export DBPass

}

action::process_config(){
    # $1 => $file path
    util::clear_domain_file_vars
    . $rootDir/deployer/DB_connection.sh --source-only

    export DOMAIN_FILE=$(basename "$1" .sh)

    if [ -z "$DOMAIN_FILE" ]; then
        echo "!!! Could not resolve a config name from '$1' - skipping"
        return 1
    fi

    if [ ! -f "$rootDir/configs/$DOMAIN_FILE.sh" ]; then
        echo "!!! Config file not found: $rootDir/configs/$DOMAIN_FILE.sh - skipping"
        return 1
    fi

    if [[ $DOMAIN_FILE == *"_"* ]]; then
        DOMAIN_FILE_ARR=(${DOMAIN_FILE//_/ })
        export CONF_GROUP=${DOMAIN_FILE_ARR[0]}
        export DOMAIN_NAME=${DOMAIN_FILE_ARR[1]}
    else
        export CONF_GROUP="default"
        export DOMAIN_NAME=$DOMAIN_FILE
    fi

    . "$rootDir/configs/$DOMAIN_FILE.sh" --source-only

    if ! action::check_host_variable; then
        return 1
    fi

    export domain=$HOST

    action::resolve_volume_paths
    action::resolve_log_settings
    action::resolve_wp_tuning
    action::resolve_db_mode || return 1

    [ "$DB_mode" = shared ] || util::create_directory "$DB_volume"
    util::create_directory "$WP_volume"
    util::create_directory "$LOGS_dir"
    action::write_log_retention
    util::create_directory "$rootDir/domains/$DOMAIN_FILE"
    util::delete "$rootDir/domains/$DOMAIN_FILE/docker-compose.yml"
    [ "$DB_mode" = shared ] || action::write_db_conf
    action::write_wp_conf
    action::provision_shared_db || return 1
    action::resolve_subdomains HOST_domainsDeclaration
    task::create_containers

}

installPackageIfNotExists(){
  packageExists=$(packageIsInstalled $1);
  if [ $packageExists = 1 ]
  then
    echo "Package $1 is installed!";
  else
  	echo "Package $1 is not installed...";
    install $1;
  fi
}

packageIsInstalled() {
  return_=1
  type $1 >/dev/null 2>&1  || {
    if (npm list -g --depth=0 | grep --quiet $1) ; then
      local return_=1;
    else
      local return_=0;
    fi
  }
  echo "$return_"
}

install(){
  echo "Installing..."
  echo $1;
  case "$1" in
    "curl") install_curl ;;
    "docker") install_docker ;;
    "docker-compose") install_docker-compose ;;
    *) echo "No install method for requested package"
  esac
}

install_docker(){
  echo "Installing docker"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  sudo apt-get update
  apt-cache policy docker-ce
  sudo apt-get install -y docker-ce
}

install_docker-compose(){
  echo "Installing docker compose"
  sudo curl -o /usr/local/bin/docker-compose -L "https://github.com/docker/compose/releases/download/1.22.0/docker-compose-$(uname -s)-$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
  sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  docker-compose -v
}
