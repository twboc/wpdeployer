#!/bin/bash

preventSubshell(){
  if [[ $_ != $0 ]]
  then
    echo "Script is being sourced"
  else
    echo "Script is a subshell - please run the script by invoking . script.sh command";
    exit 1;
  fi
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
  sudo curl -o /usr/local/bin/docker-compose -L "https://github.com/docker/compose/releases/download/3.7.0/docker-compose-$(uname -s)-$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
  sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  docker-compose -v
}