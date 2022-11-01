#!/bin/bash

#########################
# INSTALL s3cmd command
# >>>>apt-get update && apt-get install -y s3cmd
#########################

set -x

BUCKET=REPLACE_ME

TOP_LEVEL=/home/geneontology
LCL_SETTINGS_DIR=$TOP_LEVEL/www/www
S3_CFG=$TOP_LEVEL/private/s3cfg.civihost

LCL_SETTINGS=$LCL_SETTINGS_DIR/LocalSettings.php

# pattern: now=2022-05-02-03-44
now=$(date +%Y-%m-%d-%H-%M)
prefix=geneontology_mediawiki-$now

cd /tmp

# Handle sql dump
pattern="\$wgDBpassword"
set +x
password=$(cat $LCL_SETTINGS | grep -v "#" | grep $pattern | tail -1 | tr ";\"=" " " | awk '{ print $2; }')
set -x
pattern="\$wgDBuser"
user=$(cat $LCL_SETTINGS | grep -v "#" | grep $pattern | tail -1 | tr ";\"=" " " | awk '{ print $2; }')
db_dump=$prefix.sql
set +x
echo mysqldump geneontology_mediawiki  -hlocalhost -u$user -pxxxxxx
mysqldump geneontology_mediawiki  -hlocalhost -u$user -p$password > $db_dump
ret=$?
set -x

if [[ $ret == 0 ]]; then
   tar cf sqldump-$prefix.tar $db_dump
   rm -f $db_dump
   gzip -c sqldump-$prefix.tar > sqldump-$prefix.tar.gz
   rm -f sqldump-$prefix.tar
else
   rm -f $db_dump
   echo "Failed to create sql dump"
   exit 1
fi

s3cmd -c $S3_CFG put sqldump-$prefix.tar.gz s3://$BUCKET/sqldump-$prefix.tar.gz
ret=$?
if [[ $ret == 0 ]]; then
   rm -f sqldump-$prefix.tar.gz 
else
   rm -f sqldump-$prefix.tar.gz 
   echo "Failed to upload wiki sql dump"
   exit 2 
fi

# Handle Wiki Files 
tar cf wikidump-$prefix.tar $TOP_LEVEL/www

ret=$?
if [[ $ret == 0 ]]; then
   gzip -c wikidump-$prefix.tar > wikidump-$prefix.tar.gz
   rm -f wikidump-$prefix.tar 
else
   rm -f wikidump-$prefix.tar 
   echo "Failed to create wiki dump"
   exit 3 
fi

# S3 UPLOAD
s3cmd -c $S3_CFG put wikidump-$prefix.tar.gz s3://$BUCKET/wikidump-$prefix.tar.gz
ret=$?
if [[ $ret == 0 ]]; then
   rm -f wikidump-$prefix.tar.gz
else
   rm -f wikidump-$prefix.tar.gz
   echo "Failed to upload wiki file dump"
   exit 4 
fi

exit 0
