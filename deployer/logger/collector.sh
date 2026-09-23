#!/bin/sh
set -u

LOGROOT="${LOGROOT:-/volumes}"
DEFAULT_RETENTION_DAYS="${RETENTION_DAYS:-7}"
DEFAULT_MAX_SIZE_MB="${MAX_SIZE_MB:-500}"
PRUNE_INTERVAL="${PRUNE_INTERVAL:-3600}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-30}"
LABEL_ON="wpdeployer.logs=true"
STATE=/run/wpdeployer-logger

mkdir -p "$STATE"

stamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
today(){ date -u +%Y-%m-%d; }
note(){ printf '%s %s\n' "$(stamp)" "$*"; }

label_of(){ docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null; }

last_timestamp(){
  _dir=$1
  _pfx=$2
  _f=$(ls -1 "$_dir/$_pfx-"*.log 2>/dev/null | sort | tail -n1)
  [ -n "$_f" ] || return 0
  tail -n1 "$_f" 2>/dev/null | cut -d' ' -f1
}

writer(){
  awk -v dir="$1" -v pfx="$2" '
    {
      d = substr($1, 1, 10)
      if (length(d) != 10) d = "undated"
      f = dir "/" pfx "-" d ".log"
      print >> f
      fflush(f)
      if (prev != "" && prev != f) close(prev)
      prev = f
    }'
}

follow(){
  _name=$1
  _dir=$2
  _pfx=$3
  _stream=$4
  _since=$(last_timestamp "$_dir" "$_pfx")
  if [ -n "$_since" ]; then
    set -- --since "$_since"
  else
    set -- --tail 0
  fi
  if [ "$_stream" = out ]; then
    docker logs -f --timestamps "$@" "$_name" 2>/dev/null | writer "$_dir" "$_pfx"
  else
    docker logs -f --timestamps "$@" "$_name" 2>&1 1>/dev/null | writer "$_dir" "$_pfx"
  fi
}

ensure(){
  _name=$1
  _site=$(label_of "$_name" wpdeployer.site)
  [ -n "$_site" ] || return 0
  _svc=$(label_of "$_name" wpdeployer.service)
  [ -n "$_svc" ] || _svc=$_name
  _dir="$LOGROOT/$_site/logs"
  mkdir -p "$_dir" || return 0
  for _s in out err; do
    _pid="$STATE/$_name.$_s.pid"
    if [ -f "$_pid" ] && kill -0 "$(cat "$_pid" 2>/dev/null)" 2>/dev/null; then
      continue
    fi
    follow "$_name" "$_dir" "$_svc-$_s" "$_s" &
    echo $! > "$_pid"
    note "following $_name ($_s) -> $_dir/$_svc-$_s-$(today).log"
  done
}

reconcile(){
  docker ps --filter "label=$LABEL_ON" --format '{{.Names}}' 2>/dev/null | while read -r n; do
    [ -n "$n" ] && ensure "$n"
  done
}

record_event(){
  _action=$1
  _name=$2
  _site=$3
  _exit=$4
  _dir="$LOGROOT/$_site/logs"
  mkdir -p "$_dir" || return 0
  _line="$(stamp) action=$_action container=$_name"
  [ -n "$_exit" ] && _line="$_line exit=$_exit"
  case "$_action" in
    die|oom|kill)
      _oom=$(docker inspect -f '{{.State.OOMKilled}}' "$_name" 2>/dev/null)
      _restarts=$(docker inspect -f '{{.RestartCount}}' "$_name" 2>/dev/null)
      _mem=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
      _line="$_line oomkilled=${_oom:-unknown} restarts=${_restarts:-unknown} host_mem_available_kb=${_mem:-unknown}"
      ;;
  esac
  printf '%s\n' "$_line" >> "$_dir/events-$(today).log"
}

events(){
  docker events --filter type=container \
    --format '{{.Action}}|{{.Actor.Attributes.name}}|{{index .Actor.Attributes "wpdeployer.site"}}|{{index .Actor.Attributes "exitCode"}}' \
    2>/dev/null |
  while IFS='|' read -r action name site exitcode; do
    [ -n "$site" ] || continue
    case "$action" in
      start|restart|die|kill|oom|destroy|health_status) ;;
      *) continue ;;
    esac
    record_event "$action" "$name" "$site" "$exitcode"
    [ "$action" = start ] && ensure "$name"
  done
}

prune_dir(){
  _dir=$1
  _days=$DEFAULT_RETENTION_DAYS
  _max=$DEFAULT_MAX_SIZE_MB
  if [ -f "$_dir/.retention" ]; then
    _d=$(sed -n 's/^days=//p' "$_dir/.retention" 2>/dev/null)
    _m=$(sed -n 's/^maxmb=//p' "$_dir/.retention" 2>/dev/null)
    [ -n "$_d" ] && _days=$_d
    [ -n "$_m" ] && _max=$_m
  fi
  find "$_dir" -maxdepth 1 -type f -name '*.log' -mtime +"$_days" -delete 2>/dev/null
  while :; do
    _cur=$(du -sm "$_dir" 2>/dev/null | cut -f1)
    [ -n "$_cur" ] || break
    [ "$_cur" -le "$_max" ] && break
    _oldest=$(ls -1t "$_dir"/*.log 2>/dev/null | tail -n1)
    [ -n "$_oldest" ] || break
    rm -f "$_oldest"
    note "size cap ${_max}MB exceeded in $_dir, removed $(basename "$_oldest")"
  done
}

prune(){
  for d in "$LOGROOT"/*/logs; do
    [ -d "$d" ] && prune_dir "$d"
  done
}

note "wpdeployer logger starting (root=$LOGROOT retention=${DEFAULT_RETENTION_DAYS}d cap=${DEFAULT_MAX_SIZE_MB}MB)"

events &
( while :; do prune; sleep "$PRUNE_INTERVAL"; done ) &

while :; do
  reconcile
  sleep "$RECONCILE_INTERVAL"
done
