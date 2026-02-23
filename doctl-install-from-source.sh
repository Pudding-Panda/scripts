#!/bin/bash

(curl -sL https://github.com/digitalocean/doctl/releases/download/v1.8.0/doctl-1.8.0-linux-amd64.tar.gz | tar -xzv)
&& mv doctl /usr/bin/doctl
