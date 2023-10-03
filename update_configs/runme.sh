#!/bin/bash


for i in qa production staging internal
do
  export CONTEXT=$i
  export WORKSPACE=''
  ansible-playbook -i hosts-inventory -i hosts/$i-hosts deploy.yml
done
