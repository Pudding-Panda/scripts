#!/bin/sh

# This script creates a user for sftp access
# It adds the users home folder and creates a couple useful folders for organization
# you can feed a username throught the first argument to the script

USER="$1"

echo "
Match User ${USER}
 ChrootDirectory /home/${USER}
 X11Forwarding no
 AllowTcpForwarding no
 ForceCommand internal-sftp
" | tee -a /etc/ssh/sshd_config
adduser ${USER}
usermod -aG ${USER} www-data
mkdir -p /home/${USER}/www
mkdir -p /home/${USER}/data
chmod -R 0750 /home/${USER}
chown -R root.${USER} /home/${USER}
chown -R ${USER}.${USER} /home/${USER}/www/
chown -R ${USER}.${USER} /home/${USER}/data/
systemctl restart sshd
