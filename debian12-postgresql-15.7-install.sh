#!/usr/bin/env bash

apt update
sh -c "echo 'deb http://apt.postgresql.org/pub/repos/apt/debian/ bullseye-pg15 main' > /etc/apt/sources.list.d/pgdg15.list"

wget --output-document=/tmp/pgdg.key.gpg "http://apt.postgresql.org/pub/repos/apt/key.gpg"
apt-key add /tmp/pgdg.key.gpg
rm /tmp/pgdg.key.gpg

apt update
apt install postgresql-15 postgresql-client-15

systemctl status postgresql