#!/bin/bash
set -uo pipefail

if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null || { echo "[FAIL] sudo is required" >&2; exit 1; }
  echo "Snapshot for $(id -un): asking for sudo to read all files and containers"
  pass=()
  for v in SNAPSHOT_DEST SNAPSHOT_JOBS SNAPSHOT_ZSTD_THREADS SNAPSHOT_ZSTD_LEVEL SNAPSHOT_KEEP SNAPSHOT_FORCE; do
    [ -n "${!v:-}" ] && pass+=("$v=${!v}")
  done
  exec sudo env "${pass[@]}" SNAPSHOT_OWNER="$(id -un)" bash "$(readlink -f "$0")" "$@"
fi

SRC=$(cd "$(dirname "$0")" && pwd)
DEST_ROOT=${SNAPSHOT_DEST:-$(dirname "$SRC")/wpdeployer-backups/snapshots}
JOBS=${SNAPSHOT_JOBS:-4}
ZSTD_THREADS=${SNAPSHOT_ZSTD_THREADS:-2}
ZSTD_LEVEL=${SNAPSHOT_ZSTD_LEVEL:-3}
KEEP=${SNAPSHOT_KEEP:-3}
OWNER=${SNAPSHOT_OWNER:-${SUDO_USER:-}}
[ -n "$OWNER" ] && [ "$OWNER" != root ] || OWNER=$(stat -c %U "$(dirname "$SRC")")

die(){ echo "[FAIL] $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v zstd >/dev/null || die "zstd is not installed (apt install zstd)"
command -v flock >/dev/null || die "flock is not installed (apt install util-linux)"
tar --version 2>/dev/null | grep -q 'GNU tar' || die "GNU tar is required"
case "$DEST_ROOT/" in "$SRC"/*) die "destination $DEST_ROOT is inside $SRC" ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "SNAPSHOT_JOBS must be a positive number"
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "SNAPSHOT_KEEP must be a positive number"
id -u "$OWNER" >/dev/null 2>&1 || die "owner '$OWNER' does not exist (set SNAPSHOT_OWNER)"
OWNER_GROUP=$(id -gn "$OWNER")

mkdir -p "$DEST_ROOT" && chmod 700 "$DEST_ROOT" && chown "$OWNER:$OWNER_GROUP" "$DEST_ROOT" || die "cannot create $DEST_ROOT"
PARENT=$(dirname "$DEST_ROOT")
[ "$(stat -c %U "$PARENT")" = root ] && [ "$PARENT" != / ] && [ "$(dirname "$PARENT")" = "$(dirname "$SRC")" ] && chown "$OWNER:$OWNER_GROUP" "$PARENT"
exec 9>"$DEST_ROOT/.lock"
flock -n 9 || die "another snapshot is already running"
TS=$(date +%Y%m%d-%H%M%S)
while [ -e "$DEST_ROOT/$TS" ] || [ -e "$DEST_ROOT/$TS.incomplete" ]; do sleep 1; TS=$(date +%Y%m%d-%H%M%S); done
WORK="$DEST_ROOT/$TS.partial"
for stale in "$DEST_ROOT"/*.partial; do
  [ -d "$stale" ] && rm -rf "$stale" && echo "Removed unfinished snapshot $(basename "$stale")"
done

echo "Source:      $SRC"
echo "Destination: $DEST_ROOT/$TS"
echo "Measuring source size..."
SRC_KB=$(du -sk "$SRC" 2>/dev/null | cut -f1)
FREE_KB=$(df -Pk "$DEST_ROOT" | awk 'NR==2 {print $4}')
echo "Source $((SRC_KB / 1024)) MiB, free on destination $((FREE_KB / 1024)) MiB"
if [ "${SNAPSHOT_FORCE:-0}" != 1 ] && [ "$FREE_KB" -lt $(( SRC_KB + 1048576 )) ]; then
  die "not enough free space (need about $(( (SRC_KB + 1048576) / 1024 )) MiB); set SNAPSHOT_FORCE=1 to try anyway"
fi

mkdir -p "$WORK/volumes" "$WORK/volumes_shared" "$WORK/db" "$WORK/.status" "$WORK/.logs" || die "cannot create $WORK"
START=$(date +%s)

archive_job(){
  local kind=$1 name=$2 out dir log st rc
  case "$kind" in
    base)   out="$WORK/base.tar.zst" ;;
    volume) out="$WORK/volumes/$name.tar.zst"; dir="$SRC/volumes" ;;
    shared) out="$WORK/volumes_shared/$name.tar.zst"; dir="$SRC/volumes_shared" ;;
  esac
  log="$WORK/.logs/$kind-$name.log"
  st="$WORK/.status/$kind-$name"
  if [ "$kind" = base ]; then
    nice -n 19 ionice -c3 tar -C "$SRC" --numeric-owner --warning=no-file-changed --warning=no-file-removed \
      --exclude=./volumes --exclude=./volumes_shared -cf - . 2>"$log" \
      | zstd -q -T"$ZSTD_THREADS" -"$ZSTD_LEVEL" -o "$out.part" 2>>"$log"
  else
    nice -n 19 ionice -c3 tar -C "$dir" --numeric-owner --warning=no-file-changed --warning=no-file-removed \
      -cf - "$name" 2>"$log" \
      | zstd -q -T"$ZSTD_THREADS" -"$ZSTD_LEVEL" -o "$out.part" 2>>"$log"
  fi
  local ps=("${PIPESTATUS[@]}")
  rc=${ps[0]}
  if [ "$rc" -gt 1 ] || [ "${ps[1]}" != 0 ]; then
    echo "FAIL tar=$rc zstd=${ps[1]}" > "$st"; rm -f "$out.part"; echo "  [FAIL] $kind $name"; return 0
  fi
  if ! zstd -q -t "$out.part" 2>>"$log"; then
    echo "FAIL verify" > "$st"; rm -f "$out.part"; echo "  [FAIL] $kind $name (verify)"; return 0
  fi
  mv "$out.part" "$out"
  if [ "$rc" = 1 ]; then
    echo "WARN files changed during copy" > "$st"; echo "  [WARN] $kind $name (files changed while copying)"
  else
    echo "OK" > "$st"; echo "  [ OK ] $kind $name"
  fi
}

dump_job(){
  local kind=$1 name=$2 container user pass out log st
  log="$WORK/.logs/db-$name.log"
  st="$WORK/.status/db-$name"
  if [ "$kind" = dbsite ]; then
    container="$name-mariadb"
    user=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name-wordpress" 2>/dev/null | sed -n 's/^WORDPRESS_DB_USER=//p')
    pass=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name-wordpress" 2>/dev/null | sed -n 's/^WORDPRESS_DB_PASSWORD=//p')
    out="$WORK/db/$name.sql.zst"
  else
    container="wpdb-$name"
    user=root
    pass=$(sed -n 's/^export DBG_rootPass=//p' "$SRC/db_groups/$name.sh" 2>/dev/null | tail -n1)
    out="$WORK/db/shared-$name.sql.zst"
  fi
  if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "FAIL no credentials" > "$st"; echo "  [FAIL] db $name (no credentials)"; return 0
  fi
  local opts
  for opts in "--events" "--skip-events"; do
    docker exec -e MYSQL_PWD="$pass" "$container" mariadb-dump -u"$user" --all-databases \
      --single-transaction --quick --routines --triggers $opts 2>"$log" \
      | zstd -q -T1 -"$ZSTD_LEVEL" -o "$out.part" 2>>"$log"
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] && zstd -q -t "$out.part" 2>>"$log" \
       && zstd -dc "$out.part" 2>/dev/null | tail -n1 | grep -q 'Dump completed'; then
      mv "$out.part" "$out"
      echo "OK $opts" > "$st"; echo "  [ OK ] db $name"; return 0
    fi
    rm -f "$out.part"
  done
  echo "FAIL dump" > "$st"; echo "  [FAIL] db $name"
}

export SRC WORK ZSTD_THREADS ZSTD_LEVEL
export -f archive_job dump_job

JOBLIST="$WORK/.jobs"
{
  echo "base base"
  for d in "$SRC"/volumes/*; do [ -e "$d" ] && echo "volume $(basename "$d")"; done
  for d in "$SRC"/volumes_shared/*; do [ -e "$d" ] && echo "shared $(basename "$d")"; done
} > "$JOBLIST"
DBLIST="$WORK/.dbjobs"
{
  docker ps --format '{{.Names}}' | sed -n 's/-mariadb$//p' | while read -r s; do
    [ -f "$SRC/configs/$s.sh" ] && echo "dbsite $s"
  done
  docker ps --format '{{.Names}}' | sed -n 's/^wpdb-//p' | while read -r g; do echo "dbshared $g"; done
} > "$DBLIST"

echo
echo "== Databases: $(wc -l < "$DBLIST") dumps, $JOBS at a time"
xargs -r -P "$JOBS" -L 1 bash -c 'dump_job "$@"' _ < "$DBLIST"

echo
echo "== Files: $(wc -l < "$JOBLIST") archives, $JOBS at a time, zstd -$ZSTD_LEVEL with $ZSTD_THREADS threads each"
xargs -r -P "$JOBS" -L 1 bash -c 'archive_job "$@"' _ < "$JOBLIST"

echo
echo "== Checksums"
( cd "$WORK" && find . -name '*.zst' -type f -print0 | sort -z | xargs -0 -P "$JOBS" -n 20 sha256sum ) > "$WORK/SHA256SUMS.tmp"
sort -k2 "$WORK/SHA256SUMS.tmp" > "$WORK/SHA256SUMS" && rm -f "$WORK/SHA256SUMS.tmp"

TOTAL_JOBS=$(( $(wc -l < "$JOBLIST") + $(wc -l < "$DBLIST") ))
DONE=$(ls "$WORK/.status" | wc -l)
FAILS=$(grep -l '^FAIL' "$WORK/.status"/* 2>/dev/null | xargs -r -n1 basename)
WARNS=$(grep -l '^WARN' "$WORK/.status"/* 2>/dev/null | xargs -r -n1 basename)
[ "$DONE" = "$TOTAL_JOBS" ] || FAILS="$FAILS
missing status for $(( TOTAL_JOBS - DONE )) jobs"
FAILS=$(printf '%s\n' "$FAILS" | sed '/^$/d')
ELAPSED=$(( $(date +%s) - START ))

{
  echo "Snapshot $TS of $SRC"
  echo "Git: $(git -C "$SRC" log --oneline -1 2>/dev/null)"
  echo "Duration: $((ELAPSED / 60)) min $((ELAPSED % 60)) s"
  echo "Size: $(du -sh "$WORK" | cut -f1) (source $((SRC_KB / 1024)) MiB)"
  echo "Jobs: $TOTAL_JOBS, failed: $(printf '%s' "$FAILS" | grep -c .), with changed files: $(printf '%s' "$WARNS" | grep -c .)"
  echo
  echo "Failed:"; printf '%s\n' "$FAILS" | sed '/^$/d; s/^/  /'
  echo "Changed during copy:"; printf '%s\n' "$WARNS" | sed '/^$/d; s/^/  /'
  echo
  echo "Running containers at snapshot time:"
  docker ps --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' | sort
} > "$WORK/MANIFEST.txt"

cat > "$WORK/RESTORE.txt" <<'EOF'
Check archives:   sha256sum -c SHA256SUMS
Code and configs: mkdir -p /restore && tar -C /restore --numeric-owner -I zstd -xf base.tar.zst
One site files:   tar -C /home/serwery/wpdeployer/volumes --numeric-owner -I zstd -xf volumes/<site>.tar.zst
One site DB dump: zstd -dc db/<site>.sql.zst | docker exec -i -e MYSQL_PWD=<pass> <site>-mariadb mariadb -uroot
Shared group DB:  zstd -dc db/shared-<group>.sql.zst | docker exec -i -e MYSQL_PWD=<root pass> wpdb-<group> mariadb -uroot
EOF

if [ -z "$FAILS" ]; then
  mv "$WORK" "$DEST_ROOT/$TS"
  FINAL="$DEST_ROOT/$TS"
  ls -1d "$DEST_ROOT"/[0-9]*-[0-9]* 2>/dev/null | grep -Ev '\.(partial|incomplete)$' | sort -r | tail -n +$(( KEEP + 1 )) | while read -r old; do
    [ -f "$old/MANIFEST.txt" ] && [ -f "$old/SHA256SUMS" ] && rm -rf "$old" && echo "Removed old snapshot $(basename "$old")"
  done
else
  mv "$WORK" "$DEST_ROOT/$TS.incomplete"
  FINAL="$DEST_ROOT/$TS.incomplete"
fi

chown -R "$OWNER:$OWNER_GROUP" "$DEST_ROOT"
find "$FINAL" -type d -exec chmod 700 {} + && find "$FINAL" -type f -exec chmod 600 {} +

echo
sed -n '1,/^Changed during copy:/p' "$FINAL/MANIFEST.txt" | sed '$d'
printf '%s\n' "$WARNS" | sed '/^$/d; s/^/  changed: /'
echo "Saved: $FINAL (owner $OWNER)"
[ -z "$FAILS" ] || { echo "Snapshot INCOMPLETE - logs in $FINAL/.logs"; exit 1; }
