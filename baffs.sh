#!/usr/bin/env bash

docker pull justinzhf/baffs:latest
docker run  -d --name baffs --privileged=true -v ./:/opt -v /var/run/docker.sock:/var/run/docker.sock  -v /tmp/docker:/var/lib/docker justinzhf/baffs:latest

