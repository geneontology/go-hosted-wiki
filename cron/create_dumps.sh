#!/bin/bash
# Monthly wiki backup to S3: one SQL dump, one tarball of the wiki files, and
# a completion object listing both. Both dumps are streamed into S3; the
# script writes nothing to local disk beyond the log and a few bytes of
# counters per run.
#
# INVARIANT: a run that exits 0 and logs "done" has put three objects in S3:
# sqldump-<prefix>.sql.gz, wikidump-<prefix>.tar.gz and backup-<prefix>.ok,
# the last written only after both uploads were size-checked; so a pair
# without its .ok was a failed run, whatever the listing looks like.
# PRE:  s3cmd >= 1.5.1 (stdin upload); $S3_CFG readable; $MYCNF (see below)
#       present; $TOP_LEVEL/www is a real directory holding www/LocalSettings.php;
#       the panel cron runs this as the account user. The S3 identity needs
#       s3:PutObject on the bucket's objects and s3:ListBucket on the bucket.
# POST: nonzero exit and a "FAILED:" log line on any failure the script can
#       see; a signal it can catch ends the same way once the running stage
#       finishes. A producer dying mid-stream still leaves a truncated object
#       under its final key (s3cmd completes the upload on end-of-input); the
#       missing .ok is the signal. A signal during the final upload can
#       leave a complete, verified set with its .ok and still log FAILED:
#       the .ok is the record of the objects, the log of the run. DRYRUN=1
#       runs every stage but uploads nothing and marks its log lines
#       "(dryrun)".
# CAVEAT: never stage a dump on local disk: the account's scratch quota cut
#       the old on-disk tar off at ~3.3 GiB every month with exit 0.
# CAVEAT: any nonzero tar exit, including 1 ("file changed as we read it"),
#       fails the run on purpose; none has occurred at the cron hour so far.
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
MIN_SQL_BYTES=10000000     # the compressed dump is ~88 MB; anything near empty is a failure
MIN_WIKI_BYTES=500000000   # the compressed files tarball is ~1.66 GB

# MySQL client credentials live in their own 0600 option file (NOT scraped
# from LocalSettings.php: PHP quoting and MySQL option-file quoting differ,
# and "#", "\" or ";" in a password silently truncate a scraped value):
#   [client]
#   user="<wgDBuser>"
#   password="<the value PHP evaluates wgDBpassword to, with \ and " backslash-escaped>"
#   host=localhost
# --defaults-file reads only this file; HOME is pointed at the work dir so
# no ~/.my.cnf or ~/.mylogin.cnf can override it.
MYCNF=$TOP_LEVEL/private/my.cnf
MYSQLDUMP=/usr/local/bin/mysqldump

DRY=""; [ "$DRYRUN" = 1 ] && DRY=" (dryrun)"
log() { echo "$(date +%FT%T%z) $*" | tee -a "$LOG" >&2; }
died=0
die() { died=1; log "FAILED$DRY: $1"; exit "${2:-1}"; }   # $2 = exit code
WORK=""
# EXIT: remove the counter files, and log an exit that no die() announced (an
# unbound variable under set -u, a bash error) so every nonzero exit leaves a line.
trap 'rc=$?; [ -n "$WORK" ] && rm -rf "$WORK"; [ "$rc" = 0 ] || [ "$died" = 1 ] || log "FAILED$DRY: exit $rc with no diagnosis"' EXIT
# A catchable signal lands here after the running stage returns: FAILED in
# the log, nonzero exit, no .ok. (bash runs the trap when the foreground
# command finishes, not before.)
trap 'die "stopped by a signal" 5' TERM HUP INT

# --- preflight: every failure here is loud and logged -----------------------
[ -n "$BUCKET" ] && [ "$BUCKET" != REPLACE_ME ] || die "BUCKET is not set" 1
[ -x "$MYSQLDUMP" ] || die "missing executable: $MYSQLDUMP" 1
# The pipeline tools are resolved on the pinned PATH and then called by that
# path, so what was checked is what runs.
for v in S3CMD:s3cmd TAR:tar GZIP:gzip TEE:tee TAIL:tail SHA256SUM:sha256sum; do
  exe=$(command -v "${v#*:}") || die "missing executable on PATH: ${v#*:}" 1
  printf -v "${v%%:*}" '%s' "$exe"
done
for x in awk stat wc date mktemp find grep cat tr seq mkdir rm sleep printf; do
  command -v "$x" >/dev/null || die "missing executable on PATH: $x" 1
done
mode=$(stat -c %a "$MYCNF" 2>/dev/null) || die "$MYCNF missing" 1
[ "$mode" = 600 ] || [ "$mode" = 400 ] || die "$MYCNF is mode $mode, not 0600/0400" 1
[ -r "$S3_CFG" ] || die "$S3_CFG missing or unreadable" 1
[ -d "$TOP_LEVEL/www" ] && [ ! -L "$TOP_LEVEL/www" ] || die "$TOP_LEVEL/www is not a real directory" 1
[ -f "$TOP_LEVEL/www/www/LocalSettings.php" ] || die "$TOP_LEVEL/www/www/LocalSettings.php missing: wrong tree?" 1

# pattern: now=2022-05-02-03-44
now=$(date +%Y-%m-%d-%H-%M) && [ -n "$now" ] || die "date failed" 1
prefix=$DB-$now

# $WORK holds the byte counts, hashes and dump tail written by the stream
# stages' side readers: a few hundred bytes per run.
TMPROOT=$TOP_LEVEL/private/tmp
mkdir -p "$TMPROOT" || die "cannot create $TMPROOT" 1
find "$TMPROOT" -mindepth 1 -maxdepth 1 -name 'wikibackup.*' -mmin +720 -exec rm -rf {} +   # leftovers of a killed run
WORK=$(mktemp -d "$TMPROOT/wikibackup.XXXXXX") || die "mktemp failed" 1

s3_size() { # key -> byte size of the object in S3, or empty (needs s3:ListBucket only)
  local uri="s3://$BUCKET/$1" out
  out=$("$S3CMD" -c "$S3_CFG" ls "$uri" 2>&1) || log "s3cmd ls $uri failed: $(printf '%s' "$out" | tail -n 1)"
  printf '%s\n' "$out" | awk -v u="$uri" '$NF == u {print $3; exit}'   # uri is last (list_md5 adds a column before it)
}
upload() { # src(- for stdin) key
  if [ "$DRYRUN" = 1 ]; then cat "$1" > /dev/null; echo "dryrun: skipped upload of $2" >&2; return 0; fi
  "$S3CMD" -c "$S3_CFG" --no-progress put "$1" "s3://$BUCKET/$2"
}
wait_for() { # file... -> each non-empty within 30 s (process-substitution writers)
  local f
  for f in "$@"; do
    for _ in $(seq 1 30); do [ -s "$f" ] && break; sleep 1; done
    [ -s "$f" ] || return 1
  done
}
pipeline_ok() { # exit-code stage-name... ; $st holds the pipeline's PIPESTATUS
  # Checked last stage first: an upload failure closes the pipe and the
  # stages before it die of SIGPIPE (141), which would otherwise be blamed
  # on the first one.
  local code=$1 i; shift
  for ((i = $#; i >= 1; i--)); do
    [ "${st[i-1]}" = 0 ] || die "${!i} (exit ${st[i-1]}; pipeline ${st[*]})" "$code"
  done
}
stream_ok() { # key floor sizefile sumfile exit-code -> sets size and sum
  local key=$1 floor=$2 sizefile=$3 sumfile=$4 code=$5 remote
  wait_for "$sizefile" "$sumfile" || die "no byte count or hash captured for $key" "$code"
  size=$(tr -d ' \n' < "$sizefile")
  sum=$(tr -d ' \n' < "$sumfile")
  [ -n "$size" ] && [ "$size" -ge "$floor" ] 2>/dev/null \
    || die "$key is ${size:-?} bytes, below the $floor floor: empty or wrong tree" "$code"
  [[ $sum =~ ^[0-9a-f]{64}$ ]] || die "no sha256 captured for $key" "$code"
  if [ "$DRYRUN" != 1 ]; then
    remote=$(s3_size "$key")
    [ -n "$remote" ] && [ "$size" = "$remote" ] || die "$key size mismatch streamed=$size s3=${remote:-none}" "$code"
  fi
  log "ok$DRY $key $size bytes sha256=$sum"
}

log "start$DRY $prefix"

# --- SQL dump -------------------------------------------------------------
# Streamed: mysqldump | tee(tail) | gzip | tee(count, hash) | s3cmd. The tail
# of the uncompressed dump carries mysqldump's completion marker.
# No --single-transaction: the DB holds MyISAM tables (ext_TableEdit_*,
# searchindex); the default --lock-tables read-locks the whole database for
# the ~20 s dump, which is consistent across engines and has worked monthly.
# --no-tablespaces: the account lacks PROCESS, so mysqldump >= 5.7.31 prints an
# access-denied error for the tablespace query and still exits 0; MediaWiki
# uses no general tablespaces, so the dump loses nothing.
sqlkey=sqldump-$prefix.sql.gz
HOME=$WORK "$MYSQLDUMP" --defaults-file="$MYCNF" --no-tablespaces --comments --dump-date "$DB" \
  | "$TEE" >("$TAIL" -c 200 > "$WORK/sql.tail") \
  | "$GZIP" -c \
  | "$TEE" >(wc -c > "$WORK/sql.size") >("$SHA256SUM" | awk '{print $1}' > "$WORK/sql.sum") \
  | upload - "$sqlkey"
st=("${PIPESTATUS[@]}")
pipeline_ok 2 mysqldump tee gzip tee "upload of $sqlkey"
wait_for "$WORK/sql.tail" && grep -q -- '^-- Dump completed' "$WORK/sql.tail" \
  || die "mysqldump output tail missing or without the completion marker" 2
stream_ok "$sqlkey" "$MIN_SQL_BYTES" "$WORK/sql.size" "$WORK/sql.sum" 2
sql_size=$size sql_sum=$sum

# --- Wiki files -----------------------------------------------------------
# Streamed: tar | gzip | tee(count, hash) | s3cmd. Absolute path, not
# "-C /": / and /home are traverse-only (--x) on the host and tar -C must
# open the directory. tar strips the leading "/" (one stderr notice), so
# member names stay home/geneontology/www/... as with the old script.
wikikey=wikidump-$prefix.tar.gz
"$TAR" cf - "$TOP_LEVEL/www" | "$GZIP" -c \
  | "$TEE" >(wc -c > "$WORK/wiki.size") >("$SHA256SUM" | awk '{print $1}' > "$WORK/wiki.sum") \
  | upload - "$wikikey"
st=("${PIPESTATUS[@]}")
pipeline_ok 4 "tar of $TOP_LEVEL/www" gzip tee "upload of $wikikey"
stream_ok "$wikikey" "$MIN_WIKI_BYTES" "$WORK/wiki.size" "$WORK/wiki.sum" 4
wiki_size=$size wiki_sum=$sum

# --- Completion object ------------------------------------------------------
okkey=backup-$prefix.ok
ok=$(printf '%s %s %s\n%s %s %s' "$sql_sum" "$sql_size" "$sqlkey" "$wiki_sum" "$wiki_size" "$wikikey")
ok_size=$(printf '%s\n' "$ok" | wc -c)
[ "$(printf '%s\n' "$ok" | wc -l)" = 2 ] && [ "$ok_size" -gt 140 ] || die "$okkey is malformed" 5
printf '%s\n' "$ok" | upload - "$okkey" || die "upload of $okkey" 5
if [ "$DRYRUN" != 1 ]; then
  remote_size=$(s3_size "$okkey")
  [ -n "$remote_size" ] && [ "$ok_size" = "$remote_size" ] || die "$okkey size mismatch local=$ok_size s3=${remote_size:-none}" 5
fi

log "done$DRY $prefix"
exit 0
