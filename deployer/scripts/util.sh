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
  installPackageIfNotExists "docker-compose"
}

util::create_directory(){
  echo "Creating directory: $1"
  mkdir -p $1
}

util::delete(){
  echo "Deleting: $1"
  rm -rf $1
}

util::clear_domain_file_vars(){
  export HOST_www
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

    local all=( "${base[@]}" "${unique_groups[@]}" "${configs[@]}" )
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
  cd ./deployer/base
  docker-compose up -d
  cd ../../
}

action::check_host_variable(){
  if [ -z ${HOST+x} ];
    then
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
      echo "!!!";
      echo "!!! $DOMAIN_FILE NO HOST VARIABLE IN CONFIG";
      echo "!!!";
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
      kill -INT $$
    else
      echo "HOST is set to '$HOST'";
  fi
}

action::execute_option(){
    echo "Executing Option: $option"

    if [[ $1 == $RESTART_ALL ]]; then
        util::clear_docker_containers
        action::run_base
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
        HOST_domainsDeclaration=$(printf ", %s" "${HOST_domains[@]}")
        HOST_domainsDeclaration=${HOST_domainsDeclaration:1}
    fi

    eval "$1=${HOST_domainsDeclaration}"

}


task::create_containers(){
  if [ -z "$HOST_domainsDeclaration"  ]; then
      echo ""
      echo "Domains and subdomains not created for $DOMAIN_FILE"
      echo "Omitting container configuration for $(basename $file)"
  else
      envsubst < "$rootDir/deployer/template.yml" > "$rootDir/domains/$DOMAIN_FILE/docker-compose.yml";
      sudo docker-compose -f "$rootDir/domains/$DOMAIN_FILE/docker-compose.yml" up -d
  fi
}

action::set_database_pass(){
  if [ -z "$DB_pass" ]; then 
    echo "DB_pass is unset"; 
    echo "Please set the DB_pass variable in $rootDir/deployer/DB_connection.sh file";
    return;
  else 
    echo "NO DB PASS - DB_pass is set to default '$DB_pass'"; 
  fi

  export DBPass

}

action::process_config(){
    # $1 => $file path
    . $rootDir/deployer/DB_connection.sh --source-only
    util::clear_domain_file_vars
    export DOMAIN_FILE=$(basename $1 .sh)

    if [[ $DOMAIN_FILE == *"_"* ]]; then
        DOMAIN_FILE_ARR=(${DOMAIN_FILE//_/ })
        export CONF_GROUP=${DOMAIN_FILE_ARR[0]}
        export DOMAIN_NAME=${DOMAIN_FILE_ARR[1]}
    else
        export CONF_GROUP="default"
        export DOMAIN_NAME=$DOMAIN_FILE
    fi

    . $rootDir/configs/$DOMAIN_FILE.sh --source-only
    action::check_host_variable
    export domain=$HOST
    util::create_directory $DB_volume
    util::create_directory $WP_volume
    util::create_directory "$rootDir/domains/$DOMAIN_FILE"
    util::delete $rootDir/domains/$DOMAIN_FILE/docker-compose.yml
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
