#!/bin/bash
set -u

rootDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
volumesDir="$rootDir/volumes"
tailLines="${TAIL_LINES:-400}"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

usage(){
  echo "Usage: ./logs.sh [site] [tail|report|bundle]"
  echo "  tail    print the most recent lines from every stream"
  echo "  report  write a single readable text file under volumes/<site>/reports"
  echo "  bundle  write report plus a tar.gz of the raw logs"
}

list_sites(){
  local d
  for d in "$volumesDir"/*/logs; do
    [ -d "$d" ] || continue
    basename "$(dirname "$d")"
  done
}

pick_site(){
  local sites=() s
  while IFS= read -r s; do sites+=("$s"); done < <(list_sites)
  if [ ${#sites[@]} -eq 0 ]; then
    echo "No site has a logs directory under $volumesDir" >&2
    return 1
  fi
  local choice
  select choice in "${sites[@]}"; do
    [ -n "$choice" ] && { printf '%s' "$choice"; return 0; }
  done
  return 1
}

container_state(){
  local site=$1 name
  for name in $($DOCKER ps -a --filter "label=wpdeployer.site=$site" --format '{{.Names}}' 2>/dev/null); do
    echo "--- $name"
    $DOCKER inspect "$name" --format \
'    image:        {{.Config.Image}}
    status:       {{.State.Status}}
    started:      {{.State.StartedAt}}
    finished:     {{.State.FinishedAt}}
    exit code:    {{.State.ExitCode}}
    oom killed:   {{.State.OOMKilled}}
    restarts:     {{.RestartCount}}
    memory limit: {{.HostConfig.Memory}}' 2>/dev/null
  done
}

recent_files(){
  local dir=$1 pattern=$2 days=${3:-2}
  find "$dir" -maxdepth 1 -type f -name "$pattern" -mtime -"$days" 2>/dev/null | sort
}

do_tail(){
  local site=$1 dir="$volumesDir/$site/logs" f
  [ -d "$dir" ] || { echo "No logs directory for $site" >&2; return 1; }
  for f in $(recent_files "$dir" '*.log' 2); do
    echo
    echo "===== $(basename "$f") ====="
    tail -n "$tailLines" "$f"
  done
}

do_report(){
  local site=$1
  local dir="$volumesDir/$site/logs"
  local outDir="$volumesDir/$site/reports"
  local ts out f
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$outDir/report-$site-$ts.txt"
  mkdir -p "$outDir"

  {
    echo "wpdeployer log report"
    echo "site:      $site"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"
    echo "host:      $(uname -a)"
    echo
    echo "=============================================================="
    echo "HOST RESOURCES"
    echo "=============================================================="
    free -m 2>/dev/null || true
    echo
    df -h "$volumesDir" 2>/dev/null || true
    echo
    echo "=============================================================="
    echo "CONTAINER STATE"
    echo "=============================================================="
    container_state "$site"
    echo
    echo "=============================================================="
    echo "LIFECYCLE EVENTS (restarts, exits, OOM kills)"
    echo "=============================================================="
    for f in $(recent_files "$dir" 'events-*.log' 30); do
      echo "--- $(basename "$f")"
      cat "$f"
    done
    echo
    echo "=============================================================="
    echo "CONTAINER OUTPUT (last $tailLines lines per stream, last 2 days)"
    echo "=============================================================="
    for f in $(recent_files "$dir" '*-err-*.log' 2) $(recent_files "$dir" '*-out-*.log' 2); do
      echo
      echo "--- $(basename "$f")"
      tail -n "$tailLines" "$f"
    done
    echo
    echo "=============================================================="
    echo "WORDPRESS debug.log (last $tailLines lines)"
    echo "=============================================================="
    if [ -f "$volumesDir/$site/wordpress/wp-content/debug.log" ]; then
      tail -n "$tailLines" "$volumesDir/$site/wordpress/wp-content/debug.log"
    else
      echo "(not present - set WP_debugLog=true in the config to enable it)"
    fi
  } > "$out" 2>&1

  echo "$out"
}

do_bundle(){
  local site=$1 report archive ts
  local args=()
  report=$(do_report "$site")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  archive="$volumesDir/$site/reports/logs-$site-$ts.tar.gz"
  args=(-C "$volumesDir/$site" logs -C "$volumesDir/$site/reports" "$(basename "$report")")
  if [ -f "$volumesDir/$site/wordpress/wp-content/debug.log" ]; then
    args+=(-C "$volumesDir/$site/wordpress/wp-content" debug.log)
  fi
  tar czf "$archive" "${args[@]}" 2>/dev/null
  echo "$report"
  echo "$archive"
}

site="${1:-}"
action="${2:-}"

if [ "$site" = "-h" ] || [ "$site" = "--help" ]; then usage; exit 0; fi

if [ -z "$site" ]; then
  echo "Choose a site:"
  site=$(pick_site) || exit 1
fi

if [ -z "$action" ]; then
  echo "Choose an action:"
  select action in tail report bundle; do
    [ -n "$action" ] && break
  done
fi

case "$action" in
  tail)   do_tail "$site" ;;
  report) echo "Report written to:"; do_report "$site" ;;
  bundle) echo "Written:"; do_bundle "$site" ;;
  *)      usage; exit 1 ;;
esac
