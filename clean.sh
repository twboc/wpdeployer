#!/bin/bash

# Remove /var/log
rm -rf /var/log/*

# Remove /var/tmp
rm -rf /var/tmp/*

rm -rf ~/.cache/thumbnails/*


# Removes old revisions of snaps
# CLOSE ALL SNAPS BEFORE RUNNING THIS
set -eu
snap list --all | awk '/disabled/{print $1, $3}' |
    while read snapname revision; do
        snap remove "$snapname" --revision="$revision"
    done


# Remove old unused kernels
sudo apt-get remove --purge $(dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d')



sudo apt-get autoremove --purge
sudo apt-get autoclean 
#--purge
sudo apt-get clean 
#--purge
sudo apt-get -s clean


sudo apt-get install -y deborphan
sudo apt-get remove $(deborphan)

sudo journalctl --vacuum-time 3d

rm update-linux-purge*
wget https://git.launchpad.net/linux-purge/plain/update-linux-purge
chmod +x ./update-linux-purge && ./update-linux-purge

docker image prune -af
