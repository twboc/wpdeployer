#!/bin/bash
rootDir=$(pwd);

swapsize="";
defaultSize=4G

sudo swapoff -a

echo -n "Enter swap size in gigabytes: "
read userSwapsize

re='^[0-9]+$'
if ! [[ $userSwapsize =~ $re ]] 
then
  swapsize=$defaultSize;
else
  swapsize=$userSwapsize"G";
fi

sudo fallocate -l $swapsize /swapfile

ls -lh /swapfile

sudo chmod 600 /swapfile

sudo mkswap /swapfile

sudo swapon /swapfile

sudo swapon --show

sudo cp /etc/fstab /etc/fstab.bak

echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

echo "#####################################";
echo "";

free -h