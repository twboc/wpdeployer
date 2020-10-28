#!/bin/bash

mkdir configs

cp ./deployer/example.com.sh ./configs/example.com.sh

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
   
git clone https://github.com/evertramos/docker-compose-letsencrypt-nginx-proxy-companion.git
