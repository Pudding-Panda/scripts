#!/usr/bin/env sh

#Adapted from https://stackoverflow.com/questions/70194787/ansible-on-macos-sshpass-program-workaround
# 2023-10-29 09:38

mkdir sshpass-install-temp; 
cd sshpass-install-temp; 
curl -L https://sourceforge.net/projects/sshpass/files/latest/download -o sshpass-latest.tar.gz; 
tar xvzf sshpass-latest.tar.gz; 
export version=$(ls | grep -oE '^sshpass-[0-9.]+');
echo "\033[1;33mInstalling latest version: $version \033[0m"; 
cd $version; 
./configure; 
make; 
echo "sudo make install"; 
sudo make install; cd ../../; 
rm -R sshpass-install-temp; 
echo "\033[1;33mInstallation done successfully\033[0m"
