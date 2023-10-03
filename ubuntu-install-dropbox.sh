#!/bin/bash -x
PACKAGELIST="dropbox python-gpgme"

echo "deb http://linux.dropbox.com/ubuntu xenial main" | tee -a /etc/apt/sources.list
apt-key adv --keyserver pgp.mit.edu --recv-keys 1C61A2656FB57B7E4DE0F4C1FC918B335044912E
apt update
apt install -y $PACKAGELIST
echo "Execute \(dropbox start -i\) while logged into the server to set up your account"
