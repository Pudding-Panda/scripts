#!/bin/bash

( apt update; apt install -y software-properties-common python-software-properties )

# cleanup old php packages
dpkg -l | grep php| awk '{print $2}' |tr "\n" " " | xargs apt remove --purge

echo -e "\ndeb http://mirrors.digitalocean.com/ubuntu/ precise main restricted\n deb http://mirrors.digitalocean.com/ubuntu/ precise universe" >> /etc/apt/sources.list

apt update
