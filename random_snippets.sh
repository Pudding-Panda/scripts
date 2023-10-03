
# UBUNTU 16.04 @digitalocean 

ssh root@IP_ADDRESS

# configure basic system
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8
locale-gen en_US.UTF-8
dpkg-reconfigure locales
echo "
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
" | tee -a ~/.bash_profile
touch /var/lib/cloud/instance/locale-check.skip
chmod -x /etc/update-motd.d/*
echo "DIR_MODE=0750" | tee -a /etc/adduser.conf
echo "UMASK 027" | tee -a /etc/login.defs
mkdir /etc/ssh/authorized_keys
chmod 755 /etc/ssh/authorized_keys
echo "AuthorizedKeysFile /etc/ssh/authorized_keys/%u" | tee -a /etc/ssh/sshd_config
echo "PasswordAuthentication no" | tee -a /etc/ssh/sshd_config
cp -f /root/.ssh/authorized_keys /etc/ssh/authorized_keys/root
echo "YOUR_PUBLIC_KEY" | tee -a /etc/ssh/authorized_keys/root
chmod 644 /etc/ssh/authorized_keys/root
systemctl restart sshd
apt-get update
apt-get install -y htop git joe fail2ban lshw smem siege postfix mailutils apache2-utils build-essential make g++ imagemagick
echo "
-nobackups
-mouse
-lmsg \i%k%T%W%X %n %m%y%R %M %x
-rmargin 255
-linums
" | tee -a /etc/joe/joerc

dpkg-reconfigure tzdata

postconf -e 'inet_interfaces = localhost'
postconf -e 'mydestination = '
postconf -e 'inet_protocols = ipv4'
systemctl restart postfix
echo "" >> /etc/ssh/sshd_config
echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
echo "ClientAliveCountMax 99999" >> /etc/ssh/sshd_config
systemctl restart sshd

# optional: create a sudoers enabled user and disable root
echo "PermitRootLogin no" | tee -a /etc/ssh/sshd_config
adduser nodo
usermod -aG sudo nodo
echo "YOUR_PUBLIC_KEY" | tee /etc/ssh/authorized_keys/nodo
chmod 644 /etc/ssh/authorized_keys/nodo
systemctl restart sshd

# create an sftp limited user
echo "
Match User wp_jmacedo
 ChrootDirectory /home/wp_jmacedo/var
 X11Forwarding no
 AllowTcpForwarding no
 ForceCommand internal-sftp
" | tee -a /etc/ssh/sshd_config
adduser wp_jmacedo
usermod -aG wp_jmacedo www-data
mkdir -p /home/wp_jmacedo/var/www
mkdir -p /home/wp_jmacedo/var/data
chmod -R 0750 /home/wp_jmacedo
chown -R root.wp_jmacedo /home/wp_jmacedo
chown -R takeda.takeda /home/takeda/var/www/
chown -R takeda.takeda /home/takeda/var/data/
systemctl restart sshd

# install letsencrypt, create SSL and configure auto renewal
apt-get install -y bc
git clone https://github.com/letsencrypt/letsencrypt /opt/letsencrypt
cd /opt/letsencrypt
./letsencrypt-auto certonly --standalone -d webhlg01.jmacedo.nodo.cc 
# Certs will be created inside: `/etc/letsencrypt/live/webhlg01.jmacedo.nodo.cc/`
openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
# A strong diffie-Hellman group will be created in `/etc/ssl/certs/dhparam.pem`
echo '
#!/bin/sh
service nginx stop
#/opt/letsencrypt/letsencrypt-auto renew -nvv --standalone
/root/.local/share/letsencrypt/bin/letsencrypt renew -nvv --standalone
LE_STATUS=$?
service nginx start
if [ "$LE_STATUS" != 0 ]; then
    echo Automated renewal failed:
    cat /var/log/letsencrypt/renew.log
    exit 1
fi
' | tee /usr/sbin/letsencrypt-auto-renew
chmod +x /usr/sbin/letsencrypt-auto-renew
echo "0 22 * * * root [ -x /usr/sbin/letsencrypt-auto-renew ] && /usr/sbin/letsencrypt-auto-renew > /var/log/letsencrypt/renew.log " | tee /etc/cron.d/letsencrypt
systemctl restart cron

# install database
apt-get install -y mysql-server
mysql_secure_installation
echo "[client]
user=root
password=YOUR.PASSWORD
" | tee /root/.my.cnf
chmod 600 /root/.my.cnf
echo '
[mysqld]
sql_mode="STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"
' | tee -a /etc/mysql/conf.d/mysql.cnf

# wordpress database config: modify to fit your needs
mysql -e "CREATE DATABASE wp_jmacedo DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci"
mysql -e "GRANT ALL ON wp_jmacedo.* TO 'wp_jmacedo'@'localhost' IDENTIFIED BY '06d3107baf3963a1'"
mysql -e "FLUSH PRIVILEGES"

# wordpress src
cd /home/wp_jmacedo
curl -O https://wordpress.org/latest.tar.gz
tar -xvzf latest.tar.gz
rm latest.tar.gz
cp wordpress/wp-config-sample.php wordpress/wp-config.php
mkdir wordpress/wp-content/upgrade
rm -rf var/www
mv wordpress var/www
chmod -R 770 var/www
find var/www -type f | xargs chmod 660
chown -R wp_jmacedo.wp_jmacedo var/www
# GET RANDOM KEYS USING `curl -s https://api.wordpress.org/secret-key/1.1/salt/`
# REPLACE RANDOM KEYS ON `~/html/wp-config.php` AND CONFIGURE DB PARAMS

# install php fpm and configure
apt-get install -y php-fpm php-mysql php-curl php-gd php-mbstring php-mcrypt php-xml php-xmlrpc
echo cgi.fix_pathinfo=0 | tee -a /etc/php/7.0/fpm/php.ini
echo "
[www]
user = www-data
group = www-data
listen = /run/php/www.sock
listen.owner = www-data
listen.group = www-data
php_admin_value[disable_functions] = exec,passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = off
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 100
chdir = /

[wp_jmacedo]
user = wp_jmacedo
group = wp_jmacedo
listen = /run/php/wp_jmacedo.sock
listen.owner = www-data
listen.group = www-data
php_admin_value[disable_functions] = exec,passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = off
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 100
chdir = /
" | tee /etc/php/7.0/fpm/pool.d/www.conf
systemctl restart php7.0-fpm

# install and configure httpd for php-fpm
apt-get install -y nginx-extras
htpasswd -c /etc/nginx/htpasswd wp_jmacedo
echo '
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
  worker_connections 1024;
  multi_accept on;
  use epoll;
}

worker_rlimit_nofile 200000;

http {
  server_tokens off;
  server_names_hash_bucket_size 64;

  client_body_buffer_size 10K;
  client_header_buffer_size 1k;
  client_max_body_size 10m;
  large_client_header_buffers 2 1k;
  client_body_timeout 12;
  client_header_timeout 12;
  keepalive_timeout 15;
  send_timeout 10;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_requests 99;
  reset_timedout_connection on;

  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log off;
  error_log /var/log/nginx/error.log crit;

  gzip on;
  gzip_disable "msie6";

  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-enabled/*;
}
' | tee /etc/nginx/nginx.conf
echo "
server {
  listen 80;
  server_name webhlg01.jmacedo.nodo.cc;
  return 301 https://$host$request_uri;
}

server {
  listen 443 http2 ssl;
  server_name webhlg01.jmacedo.nodo.cc;

  auth_basic 'Restricted';
  auth_basic_user_file /etc/nginx/htpasswd;

  ssl_certificate /etc/letsencrypt/live/webhlg01.jmacedo.nodo.cc/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/webhlg01.jmacedo.nodo.cc/privkey.pem;
  ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
  ssl_prefer_server_ciphers on;
  ssl_dhparam /etc/ssl/certs/dhparam.pem;
  ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';
  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:50m;
  ssl_stapling on;
  ssl_stapling_verify on;
  add_header Strict-Transport-Security max-age=15768000;

  root /home/wp_jmacedo/var/www/;
  index index.php index.html;

  location /pma/ {
    auth_basic 'Restricted';
    auth_basic_user_file /etc/nginx/htpasswd;
    alias /usr/share/phpmyadmin/;
  }

  location ~ ^/pma/(.+\.php)$ {
    auth_basic 'Restricted';
    auth_basic_user_file /etc/nginx/htpasswd;
    alias /usr/share/phpmyadmin/$1;
    fastcgi_pass   unix:/run/php/www.sock;
    fastcgi_index  index.php;
    fastcgi_param  SCRIPT_FILENAME  $request_filename;
    include fastcgi_params;
  }

  location / {
    try_files $uri $uri/ /index.php?$args;
  }

  location ~ /\.ht {
    deny all;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/wp_jmacedo.sock;
  }

}
" | tee /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
# Analyze the SSL score: https://www.ssllabs.com/ssltest/analyze.html?d=webhlg01.jmacedo.nodo.cc

# install node
cd /opt/
git clone https://github.com/tj/n.git
cd /opt/n/
make install
n lts
npm update -g npm
#curl -sL https://deb.nodesource.com/setup_4.x | -E bash -
#apt-get install -y nodejs
npm install -g pm2
pm2 startup systemd
#su -c "env PATH=$PATH:/usr/bin pm2 startup systemd -u wp_jmacedo --hp /home/wp_jmacedo"
systemctl status pm2

# basic firewall configuration
ufw app list
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw enable
ufw status

###############################
# OPTIONAL STEPS
###############################

# INSTALL s3cmd
apt-get -q -y install unzip python-setuptools
mkdir -p /opt/s3cmd
cd /opt/s3cmd
wget -q https://github.com/s3tools/s3cmd/archive/master.zip
unzip master.zip
cd s3cmd-master
python setup.py install

############
OPTIONAL REDIS STABLE
############
sudo apt-get install build-essential tcl
cd /tmp
curl -O http://download.redis.io/redis-stable.tar.gz
tar xzvf redis-stable.tar.gz
cd redis-stable
make
make test
sudo make install
sudo mkdir /etc/redis
sudo cp /tmp/redis-stable/redis.conf /etc/redis
sudo nano /etc/redis/redis.conf
# replace: supervised no
# by: supervised systemd
# replace: dir ./
# by: dir /var/lib/redis
# check if: bind 127.0.0.1
# add: requirepass YWE2MGZmY2RlOGRiZWI2Mwo

echo "
[Unit]
Description=Redis In-Memory Data Store
After=network.target
[Service]
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always
[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/redis.service

echo "sysctl -w net.core.somaxconn=65535" | tee /etc/rc.local
echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" | tee -a /etc/rc.local
echo "exit 0" | tee -a /etc/rc.local
# check: cat /proc/sys/net/core/somaxconn
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf


sudo adduser --system --group --no-create-home redis
sudo mkdir /var/lib/redis
sudo chown redis:redis /var/lib/redis
sudo chmod 770 /var/lib/redis
sudo systemctl start redis
sudo systemctl status redis
sudo systemctl enable redis




### Get Database
```
REMOTEURL=hlg.embraer.com
REMOTEDB=embraer
NAME=$REMOTEURL-`date +%y%m%d%H%M_dump.sql`

ssh root@$REMOTEURL "mysqldump $REMOTEDB >$NAME"
scp root@$REMOTEURL:$NAME $NAME

echo "DISPONIVEL EM: https://ci.nodo.cc/job/flag/job/staging/job/download%20staging%20database/ws/$NAME"
``` 
