# Restoring Mediawiki

This is to test the mediawiki dumps from the hosting service.

## Get data

- Download dumps and prepare data files
  - Download
	- Go to the Control Panel
	- Go to "Backup"
	- Select "Files" and "MySQL 5"; click "Backup now"
	- (Wait for backups to be created, may take a few minutes)
	- Click on "Download backups" tab
	- Download the created "files.tar.gz" and "mysql5.tar.gz"
        - [Optionally, for upload to go-wiki-backups, copy or rename: mysql5.tar.gz -> YYYY-MM-DD-manual-mysql5.tar.gz and files.tar.gz -> YYYY-MM-DD-manual-files.tar.gz]

## Run locally

The documentation "variables" `MYUSER` (mysql user), `MYPASS` (mysql
user password), and `RPASS` (mysql root user password) are all
arbitrary. `PATH` is dependent on your environment for any given step.

Network and mysql instance; after unpacking files from above:

```bash
docker network create mediawiki-network
docker run -d --name mysql-mediawiki -p 3306:3306 --net mediawiki-network -e MYSQL_ROOT_PASSWORD=RPASS -e MYSQL_DATABASE=go-wiki-db -e MYSQL_USER=MYUSER -e MYSQL_PASSWORD=MYPASS mysql:5.7
docker exec -i mysql-mediawiki mysql -u MYUSER -pMYPASS go-wiki-db < /PATH/geneontology_mediawiki-54671-1743530370.sql
```

Use the `docker ps` command to get the container ID of the
mysql-mediawiki instance. Let's say it's "XYZ".

To get files right; after unpacking files from above:

```bash
chmod -R 777 home
mg ./home/geneontology/www/www/LocalSettings.php
```
Change the following variables in LocalSettings.php:

```bash
$wgDBserver = "XYZ";
$wgDBname = "go-wiki-db";
$wgDBuser = "MYUSER";
$wgDBpassword = "MYPASS";
```

Get mediawiki up:

```bash
docker run -d --name mediawiki -p 8081:80 --net mediawiki-network -v /PATH/home/geneontology/www/www:/var/www/html mediawiki
```

Can view at: http://localhost:8081 .

To destroy the above setup:

```bash
docker stop mediawiki
docker stop mysql-mediawiki
docker rm mediawiki
docker rm mysql-mediawiki
docker network rm mediawiki-network
```

## Legacy method

  - Prepare
	- (Assuming downloads from above in /tmp/foo)
	- `tar -zxvf mysql5.tar.gz` should produce a file like `geneontology_mediawiki-2138-1649973677.sql`
	- `tar -zxvf files.tar.gz` should produce a file tree starting at `/tmp/foo/home/`
	- Be in cloned `go-hosted-wiki`
    - `mv /tmp/foo/home/geneontology/www/www ./wikidumps/`
    - `mv /tmp/foo/geneontology_mediawiki-xxxx.sql ./sqldumps/`
- Ready docker environment
  - `cp ./stack.yaml.sample ./stack.yaml`
	- `stack.yaml` contains the mysql root password that we'll be forcing in our environment--MYSQL\_ROOT\_PASSWORD--you can modify this to your liking if needed; to match this example, one would change it to "mypass"
	- On unix replace the user attribute in `stack.yaml`with the proper uid and gid of the user on the host machine. this can be found with the command `id -u && id -g`
	- On mac be sure to delete the user attribute in `stack.yaml`
        - Port 8080 is exposed by default; modify it if need be in `stack.yaml`.
  - `cp ./sqldumps/user.sql.sample ./sqldumps/user.sql`
	- similarly, `user.sql` contains the mysql user that we'll be forcing in our environment; you can modify this to your liking if needed; to match this example, one would not need to change anything

## Modify LocalSettings.php

Modify these variables in `wikidumps/www/LocalSettings.php` to match what you want and what was defined above in `stack.yaml` and `users.sql`.

- $wgServer = "http://your-host-or-ip:8080";
  - On mac, this is the ip for en0; on other systems, maybe a mock listing in /etc/hosts, like test.wiki.com.
  - This seems to sometimes not work so well (YMMV) for localhost and loopbacks, so trying to use a "real" IP or hostname may be preferable.
- Use credentials in `./sqldumps/user.sql` (or modify both files with a different user and password)
  - $wgDBuser = "myuser";
  - $wgDBpassword = "mypass";
  - $wgDBserver = "go-wiki-db";

## Launch stack

The steps below  will launch the mediawiki and mysql containers. The first time the mysql container is launched,
it will execute the sql scripts in sqldumps directory. When stack is ready, the wiki can be accessed at
http://{host-ip}:{exposed-port} or http://localhost:8080 if testing locally and did not modify the exposed port
in `stack.yaml`

```
docker-compose -f stack.yaml up -d
docker-compose -f stack.yaml logs -f
```
