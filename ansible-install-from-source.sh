#!/bin/bash

git clone https://github.com/ansible/ansible.git \
          --recursive\
          --branch stable-2.9 \
          --single-branch \
          --depth 1 \
          /opt/ansible
cd /opt/ansible
source ./hacking/env-setup
pip install -r ./requirements.txt
python setup.py install
