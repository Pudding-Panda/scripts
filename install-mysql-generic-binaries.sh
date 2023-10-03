#!/bin/bash

apt-get update && \
apt-get install -y wget && \
wget https://downloads.mysql.com/archives/get/file/mysql-5.5.40-linux2.6-x86_64.tar.gz && \
groupadd mysql && \
useradd -r -g mysql -s /bin/false mysql && \
cd /usr/local && \
tar zxvf /path/to/mysql-VERSION-OS.tar.gz && \
ln -s full-path-to-mysql-VERSION-OS mysql && \
cd mysql && \
mkdir mysql-files && \
chmod 750 mysql-files && \
chown -R mysql . && \
chgrp -R mysql . && \
bin/mysqld --initialize --user=mysql # MySQL 5.7.6 and up && \
bin/mysql_ssl_rsa_setup              # MySQL 5.7.6 and up && \
chown -R root . && \
chown -R mysql data mysql-files && \
bin/mysqld_safe --user=mysql && \
cp support-files/mysql.server /etc/init.d/mysql.server
