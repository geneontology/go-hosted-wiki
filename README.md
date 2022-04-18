# Restoring Mediawiki

This is to test the mediawiki dumps from the hosting service.

## Preparation

- Download dumps and prepare them
  - Download
	- Go to "Control Panel"
	- "Files" -> "Backup"
	- Select "Files" and "MySQL 5"; click "Backup now"
	- (Wait for backups to be created, may take a few minutes)
	- Click on "Download backups" tab
	- Download the created "files.tar.gz" and "mysql5.tar.gz"
  - Prepare
	- (Assuming downloads from above in /tmp/foo)
	- `tar -zxvf mysql5.tar.gz` should produce a file like `geneontology_mediawiki-2138-1649973677.sql`
	- `tar -zxvf files.tar.gz` should produce a file tree starting at `/tmp/foo/home/`
    - `mv /tmp/foo/home/geneontology/www/www ./wikidumps/`
    - `mv /tmp/foo/geneontology_mediawiki-xxxx.sql ./sqldumps/`
- Ready docker environment
  - `cp ./stack.yaml.sample ./stack.yaml`
	- `stack.yaml` contains the mysql root password that we'll be forcing in our environment--MYSQL\_ROOT\_PASSWORD--you can modify this to your liking if needed; to match this example, one would change it to "mypass"
	- On unix uncomment the user attribute in `stack.yaml` and replace it with the proper uid and gid of the user on the host machine
  - `cp ./sqldumps/user.sql.sample ./sqldumps/user.sql`
	- similarly, `user.sql` contains the mysql user that we'll be forcing in our environment; you can modify this to your liking if needed; to match this example, one would not need to change anything

## Modify wikidumps/www/LocalSettings.php

Modify these variables in LocalSettings.php to match what you want and what was defined above in `stack.yaml` and `users.sql`.

- $wgServer = "http://your-host-or-ip:8080";
  - On mac this is the ip for en0; on other systems, maybe a mock listing in /etc/hosts, like test.wiki.com.
- Use credentials in `./sqldumps/user.sql` (or modify both files with a different user and password)
  - $wgDBuser = "myuser";
  - $wgDBpassword = "mypass";
  - $wgDBserver = "go-wiki-db";

## Launch stack

The steps below  will launch the mediawiki and mysql containers. The first time the mysql container is launched,
it will execute the sql scripts in sqldumps directory. When stack is ready, the wiki can be accessed at
http://localhost:8080.

```
docker-compose -f stack.yaml up -d
docker-compose -f stack.yaml logs -f
```
