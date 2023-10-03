#!/usr/bin/env sh

export DEBIAN_FRONTEND=noninteractive

apt update \
&& apt install software-properties-common \
&& apt-add-repository ppa:ansible/ansible \
&& apt update \
&& apt install -y ansible
