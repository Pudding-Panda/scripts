#!/bin/sh

BUILDDEPENDENCIES="wget"
FILENAME="mysql-apt-config_0.8.30-1_all.deb"

echo "-- resolving build dependencies"
apt install -y $BUILDDEPENDENCIES

echo "-- downloading deb"
wget https://dev.mysql.com/get/${FILENAME}

echo '-- unpacking and installing'
export DEBIAN_FRONTEND=noninteractive
dpkg -i $FILENAME

echo '-- updating packages'
apt update
apt install mysql-server -y

rm -f $FILENAME
