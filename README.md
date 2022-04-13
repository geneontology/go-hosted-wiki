# Restoring wikk

This is to test the wiki dumps from the hosting service.

## Preparation 
  - Download wiki dump and untar it
    - mv home/geneontology/www/www wikidumps/ 
  - Download sql dump and untar it
    - mv geneontology_mediawiki-xxxx.sql sqldumps/
  - cp stack.yaml.sample to stack.yaml
  - cp sqldumps/user.sql.sample  sqldumps/user.sql

## Modify wikidumps/www/LocalSettings.php 
  - $wgServer = "http://your_host_ip:8080";
    - On mac this is the ip for en0
  - Use credentials in sqldumps/user.sql  
    - $wgDBuser = "myuser";
    - $wgDBpassword = "mypass";
  - $wgDBserver = "go-wiki-db";

## Launch stack

This will launch the mediawiki and mysql containers. The first time the mysql container is launched, 
it will execute the sql scripts in sqldumps directory. When stack is ready, the wiki can be accessed at
http://localhost:8080.

```
docker-compose -f stack.yaml up -d
docker-compose -f stack.yaml logs -f
```
