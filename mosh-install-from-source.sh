#!/bin/bash

if [[ -z $(which protoc) ]]
then
  wget https://github.com/protocolbuffers/protobuf/releases/download/v3.6.1/protobuf-all-3.6.1.tar.gz
  tar -C /opt -zxf protobuf-all-3.6.1.tar.gz
  (
    cd /opt/protobuf-3.6.1; \
    ./configure; \
    make; \
    make check; \
    make install; \
    ldconfig
  )
fi

git clone https://github.com/mobile-shell/mosh /opt/mosh
cd /opt/mosh
./autogen.sh
./configure
make
make install
