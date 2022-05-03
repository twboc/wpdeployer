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

util::clear_docker_containers(){
  sudo docker stop $(sudo docker ps -a -q)
  sudo docker rm $(sudo docker ps -a -q)
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

action::run_letsencrypt_containers(){
  cd ./docker-compose-letsencrypt-nginx-proxy-companion
  ./start.sh
  cd ../
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


