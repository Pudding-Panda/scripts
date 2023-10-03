#!/bin/sh

# This script sets up the infrastructure person's machine.
# I created this script to set up my own machine after a cleanup, reinstall or update.

USER=$(whoami)

function gclone {
  git clone git@code.nodo.cc:$1/$2.git $3
}

echo "If you have not added your key to the infrastructure group you must do so now.\nThis script expects full access to the infra stuff"

sudo chown ${USER}.${USER} /opt /tmp
sudo chmod 777 /tmp
sudo chmod 755 /opt 

# Bash Profile
mkdir -p ~/Documents
gclone(openinfra, profiles, ~/Documents/profiles)
cd ~/Documents/profiles
sh install.sh double

# Infra repo
mkdir -p ~/workspace/infrastructure
gclone(infrastructure, resources, ~/workspace/infrastructure/resources)


# Subservers 
cd ~
gclone(internalinfra, access-keys, ~/access-keys)
cd ~/access-keys
sh install.sh
rm -rf ~/access-keys



