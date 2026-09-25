#!/bin/bash
# Monthly wiki backup to S3: one SQL dump + one tarball of the wiki files.
#
# INVARIANT: local scratch peaks at the uncompressed SQL dump plus its
# compressed tarball (~0.8 GB today), under $TOP_LEVEL/private/tmp on the
# home filesystem. The files tarball is streamed straight into S3 and never
# touches disk: the previous version wrote a ~2.2 GiB tar plus a growing .gz
# into /tmp and was cut off at ~3.3 GiB total every month (partial .gz
# uploaded, exit 0).
# PRE:  s3cmd >= 1.5.1 (stdin upload); $S3_CFG readable; $MYCNF (see below)
#       present; the panel cron runs this as the account user.
# POST: both objects in S3 with sizes equal to what was produced here;
#       nonzero exit (and cron mail) on any failure. DRYRUN=1 runs every
#       stage but uploads nothing.
#
# INSTALL s3cmd: apt-get update && apt-get install -y s3cmd

set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C
umask 077

BUCKET=REPLACE_ME

TOP_LEVEL=/home/geneontology
S3_CFG=$TOP_LEVEL/private/s3cfg.civihost
LOG=$TOP_LEVEL/private/backup.log
DB=geneontology_mediawiki
DRYRUN=${DRYRUN:-0}

# MySQL client credentials live in their own 0600 option file (NOT scraped
# from LocalSettings.php: PHP quoting and MySQL option-file quoting differ,
# and "#", "\" or ";" in a password silently truncate a scraped value):
#   [client]
#   user="<wgDBuser>"
#   password="<wgDBpassword, with \ and " backslash-escaped>"
#   host=localhost
# --defaults-file reads only this file; HOME is pointed at the work dir so
# no ~/.my.cnf or ~/.mylogin.cnf can override it.
MYCNF=$TOP_LEVEL/private/my.cnf

MYSQLDUMP=/usr/local/bin/mysqldump
for x in "$MYSQLDUMP" /usr/bin/s3cmd /bin/tar /bin/gzip /usr/bin/tee; do
  [ -x "$x" ] || { echo "missing executable: $x" >&2; exit 1; }
done
[ -r "$MYCNF" ] && [ "$(stat -c %a "$MYCNF")" = 600 ] || { echo "$MYCNF missing or not mode 0600" >&2; exit 1; }
[ -r "$S3_CFG" ] || { echo "$S3_CFG missing" >&2; exit 1; }

# pattern: now=2022-05-02-03-44
now=$(date +%Y-%m-%d-%H-%M) && [ -n "$now" ] || exit 1
prefix=$DB-$now

TMPROOT=$TOP_LEVEL/private/tmp
mkdir -p "$TMPROOT" || exit 1
find "$TMPROOT" -mindepth 1 -maxdepth 1 -name 'wikibackup.*' -mmin +720 -exec rm -rf {} +   # leftovers of a killed run
WORK=$(mktemp -d "$TMPROOT/wikibackup.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

log() { echo "$(date +%FT%T%z) $*" | tee -a "$LOG"; }
die() { log "FAILED: $*"; exit "${2:-1}"; }
s3_size() { # key -> byte size of the object in S3, or empty
  s3cmd -c "$S3_CFG" info "s3://$BUCKET/$1" 2>/dev/null | awk -F': *' '$1 ~ /File size/ {print $2; exit}'
}
upload() { # src(- for stdin) key
  if [ "$DRYRUN" = 1 ]; then cat "$1" > /dev/null; echo "dryrun: skipped upload of $2" >&2; return 0; fi
  s3cmd -c "$S3_CFG" --no-progress put "$1" "s3://$BUCKET/$2"
}

log "start $prefix dryrun=$DRYRUN work=$WORK"

# --- SQL dump -------------------------------------------------------------
sql=$WORK/$prefix.sql
sqlkey=sqldump-$prefix.tar.gz
HOME=$WORK "$MYSQLDUMP" --defaults-file="$MYCNF" --comments --dump-date "$DB" > "$sql" || die "mysqldump" 2
tail -c 200 "$sql" | grep -q -- '-- Dump completed' || die "mysqldump output has no completion marker" 2
tar czf "$WORK/$sqlkey" -C "$WORK" "$(basename "$sql")" || die "tar of sql dump" 2
rm -f "$sql"
gzip -t "$WORK/$sqlkey" || die "sql tarball fails gzip -t" 2
upload "$WORK/$sqlkey" "$sqlkey" || die "upload of $sqlkey" 3
local_size=$(stat -c %s "$WORK/$sqlkey")
if [ "$DRYRUN" != 1 ]; then
  remote_size=$(s3_size "$sqlkey")
  [ "$local_size" = "$remote_size" ] || die "$sqlkey size mismatch local=$local_size s3=$remote_size" 3
fi
log "ok $sqlkey $local_size bytes"
rm -f "$WORK/$sqlkey"

# --- Wiki files -----------------------------------------------------------
# Streamed: tar | gzip | tee(count) | s3cmd. Member names stay
# home/geneontology/www/... as with the old "tar cf x /home/geneontology/www".
wikikey=wikidump-$prefix.tar.gz
sizefile=$WORK/wiki.size
tar cf - -C / "${TOP_LEVEL#/}/www" | gzip -c | tee >(wc -c > "$sizefile") | upload - "$wikikey"
st=("${PIPESTATUS[@]}")
[ "${st[0]}" = 0 ] || die "tar of $TOP_LEVEL/www (exit ${st[0]})" 4
[ "${st[1]}" = 0 ] || die "gzip (exit ${st[1]})" 4
[ "${st[2]}" = 0 ] || die "tee (exit ${st[2]})" 4
[ "${st[3]}" = 0 ] || die "upload of $wikikey (exit ${st[3]})" 4
for _ in $(seq 1 30); do [ -s "$sizefile" ] && break; sleep 1; done   # wc runs in a process substitution; give it a moment
local_size=$(cat "$sizefile" 2>/dev/null | tr -d ' ')
[ -n "$local_size" ] || die "no byte count captured for $wikikey" 4
if [ "$DRYRUN" != 1 ]; then
  remote_size=$(s3_size "$wikikey")
  [ "$local_size" = "$remote_size" ] || die "$wikikey size mismatch streamed=$local_size s3=$remote_size" 4
fi
log "ok $wikikey $local_size bytes"

log "done $prefix"
exit 0
