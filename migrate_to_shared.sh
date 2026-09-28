#!/bin/bash
set -uo pipefail

rootDir=$(cd "$(dirname "$0")" && pwd)
cd "$rootDir" || exit 1
. "$rootDir/deployer/scripts/util.sh"
util::resolve_compose >/dev/null || exit 1

BACKUPS=${WPD_BACKUPS:-$(dirname "$rootDir")/wpdeployer-backups}/shared-migrate
TS=$(date +%Y%m%d-%H%M%S)

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok(){ printf '  [ OK ] %s\n' "$*"; }
info(){ printf '  [info] %s\n' "$*"; }
die(){ printf '  [FAIL] %s\n' "$*"; exit 1; }

usage(){
  echo "Usage:"
  echo "  $0 <site> <group>      move configs/<site>.sh into shared DB group db_groups/<group>.sh"
  echo "  $0 --rollback <site>   restore the site's last dedicated config and redeploy it"
  exit 1
}

cfgval(){ sed -n "s/^[[:space:]]*export $1=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" "$CFG" | tail -n1; }

redeploy(){
  ( . "$rootDir/deployer/DB_connection.sh" --source-only; file=$CFG; action::process_config "$CFG" ) > "$BACKUPS/$SITE-$TS.deploy.log" 2>&1
}

site_ok(){
  _port=$(cfgval WP_portOut)
  _host=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SITE-wordpress" 2>/dev/null | sed -n 's/^VIRTUAL_HOST=//p' | cut -d, -f1 | tr -d ' ')
  [ -n "$_host" ] || _host=$(cfgval HOST)
  for _i in $(seq 1 30); do
    _code=$(curl -s -o "$BACKUPS/.body" -m 20 -w '%{http_code}' -H "Host: $_host" "http://127.0.0.1:$_port/")
    if [[ "$_code" =~ ^[23] ]] && ! grep -qi 'error establishing a database connection' "$BACKUPS/.body"; then
      ok "site answers HTTP $_code ($_host via port $_port)"
      rm -f "$BACKUPS/.body"
      return 0
    fi
    sleep 2
  done
  info "site answers HTTP $_code ($_host via port $_port)"
  rm -f "$BACKUPS/.body"
  return 1
}

src_sql(){ docker exec -i -e MYSQL_PWD="$SRC_PASS" "$SITE-mariadb" mariadb -u"$SRC_USER" -N -B "$@"; }

table_counts(){
  for _t in "${TABLES[@]}"; do
    printf '%s %s\n' "$_t" "$("$1" -e "SELECT COUNT(*) FROM \`$2\`.\`$_t\`" </dev/null)"
  done
}

[ "$(id -u)" = 0 ] || die "run as root"
mkdir -p "$BACKUPS" && chmod 700 "$BACKUPS"

if [ "${1:-}" = "--rollback" ]; then
  SITE=${2:-}; [ -n "$SITE" ] || usage
  CFG="$rootDir/configs/$SITE.sh"
  [ -f "$CFG" ] || die "config not found: $CFG"
  ORIG=$(ls -1t "$BACKUPS/$SITE"-*.sh.orig 2>/dev/null | head -n1)
  [ -n "$ORIG" ] || die "no saved dedicated config for $SITE in $BACKUPS"
  say "ROLLBACK $SITE"
  info "restoring $ORIG"
  info "data written to the shared DB since the move is not copied back"
  cp -p "$CFG" "$BACKUPS/$SITE-$TS.sh.shared"
  cp -p "$ORIG" "$CFG"
  redeploy || die "redeploy failed, see $BACKUPS/$SITE-$TS.deploy.log"
  site_ok || die "site does not answer after rollback, see $BACKUPS/$SITE-$TS.deploy.log"
  [ "$(docker inspect -f '{{.State.Running}}' "$SITE-mariadb" 2>/dev/null)" = true ] && ok "$SITE-mariadb running again"
  exit 0
fi

SITE=${1:-}; GROUP=${2:-}
[ -n "$SITE" ] && [ -n "$GROUP" ] || usage
CFG="$rootDir/configs/$SITE.sh"

say "PRE-FLIGHT $SITE -> $GROUP"
[ -f "$CFG" ] || die "config not found: $CFG"
[ "$(cfgval DB_mode)" = shared ] && die "$SITE is already in shared mode"
dbgroup::load "$GROUP" || die "cannot load DB group $GROUP"
COUNT=$(dbgroup::site_count "$GROUP")
[ "$COUNT" -lt "$DBG_maxSites" ] || die "group $GROUP is full ($COUNT of $DBG_maxSites)"
ok "group $GROUP has $COUNT of $DBG_maxSites sites"

for c in mariadb wordpress; do
  [ "$(docker inspect -f '{{.State.Running}}' "$SITE-$c" 2>/dev/null)" = true ] || die "$SITE-$c is not running"
done
SRC_DB=$(cfgval DB_name); SRC_USER=$(cfgval DB_user); SRC_PASS=$(cfgval DB_pass)
[ -n "$SRC_DB" ] && [ -n "$SRC_USER" ] && [ -n "$SRC_PASS" ] || die "DB_name, DB_user and DB_pass must be set in the config"
SRC_VER=$(src_sql -e 'SELECT VERSION()' 2>/dev/null) || die "cannot log in to $SITE-mariadb with the config credentials"
ok "source $SITE-mariadb $SRC_VER, database $SRC_DB"

PREFIXES=$(src_sql -e "SELECT LEFT(table_name, LENGTH(table_name)-7) FROM information_schema.tables WHERE table_schema='$SRC_DB' AND table_name LIKE '%\\_options'")
[ "$(printf '%s\n' "$PREFIXES" | grep -c .)" = 1 ] || die "expected one WordPress options table in $SRC_DB, found: ${PREFIXES:-none}"
PREFIX=$PREFIXES
LIKE=$(printf '%s' "$PREFIX" | sed 's/_/\\\\_/g')
if [ "$SRC_DB" = mysql ]; then
  mapfile -t TABLES < <(src_sql -e "SELECT table_name FROM information_schema.tables WHERE table_schema='mysql' AND table_type='BASE TABLE' AND table_name LIKE '${LIKE}%' ORDER BY table_name")
else
  mapfile -t TABLES < <(src_sql -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$SRC_DB' AND table_type='BASE TABLE' ORDER BY table_name")
fi
[ "${#TABLES[@]}" -gt 0 ] || die "no tables found"
ok "table prefix '$PREFIX', ${#TABLES[@]} tables to copy"
SITEURL=$(src_sql -e "SELECT option_value FROM \`$SRC_DB\`.\`${PREFIX}options\` WHERE option_name='siteurl'")
HOMEURL=$(src_sql -e "SELECT option_value FROM \`$SRC_DB\`.\`${PREFIX}options\` WHERE option_name='home'")
ok "siteurl $SITEURL, home $HOMEURL"

NEW_DB="wp_$(printf '%s' "$SITE" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g')"
[ ${#NEW_DB} -le 64 ] || NEW_DB="${NEW_DB:0:55}_$(printf '%s' "$SITE" | md5sum | cut -c1-8)"
NEW_USER=$NEW_DB
NEW_PASS=$(openssl rand -hex 16)
OTHER=$(grep -l "^export DB_name=$NEW_DB\$" "$rootDir"/configs/*.sh 2>/dev/null | grep -v "^$CFG\$" || true)
[ -z "$OTHER" ] || die "database name $NEW_DB is already used by: $OTHER"
MAXCONN=$(( $(cfgval WP_maxWorkers | grep -E '^[0-9]+$' || echo 10) + 5 ))
ok "target database/user $NEW_DB in $DBG_container"

say "GROUP $GROUP"
if [ "$(docker inspect -f '{{.State.Running}}' "$DBG_container" 2>/dev/null)" != true ]; then
  action::run_db_group "$GROUP" > "$BACKUPS/$GROUP-$TS.start.log" 2>&1 || die "cannot start $DBG_container, see $BACKUPS/$GROUP-$TS.start.log"
fi
dbgroup::wait_ready >/dev/null || die "$DBG_container is not healthy"
ok "$DBG_container $(dbgroup::sql -e 'SELECT VERSION()')"
dbgroup::sql <<SQL || die "cannot create database and user"
DROP DATABASE IF EXISTS \`$NEW_DB\`;
CREATE DATABASE \`$NEW_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$NEW_USER'@'%' IDENTIFIED BY '$NEW_PASS';
ALTER USER '$NEW_USER'@'%' IDENTIFIED BY '$NEW_PASS' WITH MAX_USER_CONNECTIONS $MAXCONN;
GRANT ALL PRIVILEGES ON \`$NEW_DB\`.* TO '$NEW_USER'@'%';
SQL
ok "database $NEW_DB and user created (max $MAXCONN connections)"

say "COPY"
table_counts src_sql "$SRC_DB" > "$BACKUPS/$SITE-$TS.counts.before"
DUMP="$BACKUPS/$SITE-$TS.sql.gz"
docker exec -e MYSQL_PWD="$SRC_PASS" "$SITE-mariadb" mariadb-dump -u"$SRC_USER" --single-transaction --quick --routines --triggers --default-character-set=utf8mb4 "$SRC_DB" "${TABLES[@]}" | gzip > "$DUMP"
[ "${PIPESTATUS[0]}" = 0 ] && gzip -t "$DUMP" || die "dump failed"
ok "dump $DUMP ($(du -h "$DUMP" | cut -f1))"
gunzip -c "$DUMP" | dbgroup::sql "$NEW_DB" || die "import into $NEW_DB failed"
ok "imported into $NEW_DB"
table_counts src_sql "$SRC_DB" > "$BACKUPS/$SITE-$TS.counts.after"
table_counts dbgroup::sql "$NEW_DB" > "$BACKUPS/$SITE-$TS.counts.target"

say "VERIFY"
BAD=0
while read -r t before; do
  after=$(awk -v t="$t" '$1==t{print $2}' "$BACKUPS/$SITE-$TS.counts.after")
  target=$(awk -v t="$t" '$1==t{print $2}' "$BACKUPS/$SITE-$TS.counts.target")
  if [ "$before" = "$after" ] && [ "$target" != "$before" ]; then
    printf '  [FAIL] %s: source %s rows, copy %s rows\n' "$t" "$before" "$target"; BAD=1
  elif [ "$before" != "$after" ]; then
    info "$t changed during the copy (live writes): source $before -> $after rows, copy $target"
  fi
done < "$BACKUPS/$SITE-$TS.counts.before"
[ "$BAD" = 0 ] || die "row counts differ, nothing was switched; the copy stays in $NEW_DB"
ok "row counts match for ${#TABLES[@]} tables"
T_SITEURL=$(dbgroup::sql "$NEW_DB" -e "SELECT option_value FROM \`${PREFIX}options\` WHERE option_name='siteurl'")
T_HOMEURL=$(dbgroup::sql "$NEW_DB" -e "SELECT option_value FROM \`${PREFIX}options\` WHERE option_name='home'")
[ "$T_SITEURL" = "$SITEURL" ] && [ "$T_HOMEURL" = "$HOMEURL" ] || die "siteurl/home differ in the copy"
ok "siteurl and home match"
docker run --rm --network "wpdb_$GROUP" -e MYSQL_PWD="$NEW_PASS" "$DBG_image" mariadb -h "$DBG_container" -u"$NEW_USER" -N -B -e "SELECT COUNT(*) FROM \`$NEW_DB\`.\`${PREFIX}options\`" >/dev/null 2>&1 || die "new user cannot read $NEW_DB over the group network"
ok "new user can log in over wpdb_$GROUP"

say "SWITCH"
cp -p "$CFG" "$BACKUPS/$SITE-$TS.sh.orig"
sed -i -E '/^[[:space:]]*export DB_(image|name|user|pass|host|mode|group)=/d' "$CFG"
[ -z "$(tail -c1 "$CFG")" ] || echo >> "$CFG"
cat >> "$CFG" <<EOF
export DB_mode=shared
export DB_group=$GROUP
export DB_name=$NEW_DB
export DB_user=$NEW_USER
export DB_pass=$NEW_PASS
export DB_host=$DBG_container
EOF
ok "config updated (old config: $BACKUPS/$SITE-$TS.sh.orig)"

if redeploy && site_ok; then
  ok "$SITE now uses $DBG_container"
else
  info "switch failed, restoring the dedicated config (log: $BACKUPS/$SITE-$TS.deploy.log)"
  cp -p "$BACKUPS/$SITE-$TS.sh.orig" "$CFG"
  TS=$TS-rollback redeploy
  site_ok && die "rolled back: $SITE runs on its dedicated DB again" || die "rollback also failed, check $SITE by hand"
fi

[ "$(docker inspect -f '{{.State.Running}}' "$SITE-mariadb" 2>/dev/null)" = true ] && info "$SITE-mariadb still running" || ok "$SITE-mariadb removed; data kept in volumes/$SITE/mariadb"
[ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SITE-wordpress" | sed -n 's/^WORDPRESS_DB_HOST=//p')" = "$DBG_container" ] && ok "$SITE-wordpress uses $DBG_container"

say "DONE"
echo "  Group $GROUP: $(dbgroup::site_count "$GROUP") of $DBG_maxSites sites"
echo "  Rollback: $0 --rollback $SITE"
