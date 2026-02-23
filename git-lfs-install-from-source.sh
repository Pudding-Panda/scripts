#!/bin/bash

go get github.com/git-lfs/git-lfs
cd ~/go/gihub.com/git-lfs/git-lfs/
make
mv bin/git-lfs /usr/bin/git-lfs
