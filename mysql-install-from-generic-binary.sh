#!/bin/bash -x 

BUILDDEPENDENCIES="wget libaio1"

MYSQLVERSION="5.5.58"

BASENAME="mysql-$MYSQLVERSION-linux-glibc2.12-x86_64"
BASEFOLDER="/usr/local"

FILENAME="$BASENAME.tar.gz"

USER="mysql"

# ---

apt install -y $BUILDDEPENDENCIES

cd /opt;
wget https://downloads.mysql.com/archives/get/file/$FILENAME /opt

groupadd mysql
useradd -r -g mysql -s /bin/false mysql

cd $BASEFOLDER
tar -zxvf /opt/$FILENAME
mv "$BASEFOLDER/$BASENAME" $BASEFOLDER/mysql

cd mysql
chown -R $USER $BASEFOLDER/mysql
chgrp -R $USER $BASEFOLDER/mysql

ln -s $BASEFOLDER/mysql/bin/* /usr/bin/
$BASEFOLDER/mysql/scripts/mysql_install_db --user=mysql

chown -R root $BASEFOLDER/mysql
chown -R $USER $BASEFOLDER/mysql/data

cp support-files/my-medium.cnf /etc/my.cnf

cp support-files/mysql.server /etc/init.d/mysql.server

systemctl daemon-reload
service mysql start
