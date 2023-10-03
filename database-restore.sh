#!/bin/bash

# This script transfers a database from one server to another via CI
# Receives 4 parameters FROMHOST, FROMDATABASE, TOHOST, TODATABASE

export FH=$1
export FDB=$2

export TH=$3
export TDB=$4

export TODAY=$(date +%y%m%dT%H%M)

FILENAME="${TODAY}-${FDB}_${TDB}.sql"

ssh root@${FH} "mysqldump --quick --single-transaction ${FDB} |gzip -9 -- > ${FILENAME}.gz"
scp ${FILENAME}.gz root@${TH}:${FILENAME}.gz
ssh root@${TH} "gunzip ${FILENAME}.gz && mysql ${TDB} < ${FILENAME} && rm ${FILENAME}"
