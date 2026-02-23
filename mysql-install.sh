#!/bin/sh

BUILDDEPENDENCIES="wget"
FILENAME="mysql-5.5.40-debian6.0-x86_64.deb"

echo "-- resolving build dependencies"
apt install -y $BUILDDEPENDENCIES

echo "-- downloading deb"
wget https://downloads.mysql.com/archives/get/file/$FILENAME

echo '-- unpacking and installing'
(dpkg -i $FILENAME && apt install -fy && apt autoremove -y)


rm $FILENAME
