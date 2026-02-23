#!/bin/bash -x

apt install -y git

cd /opt
git clone https://github.com/s3tools/s3cmd.git --branch master --single-branch s3cmd
cd /opt/s3cmd
python setup.py install
