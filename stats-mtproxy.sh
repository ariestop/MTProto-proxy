#!/usr/bin/env bash
# TCP session stats for the proxy listen port on the host (conntrack).
set -euo pipefail
# nohup/cron often provide a minimal PATH; conntrack is usually in /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Optional overrides (e.g. under sudo):
#   MTPROXY_CONFIG_FILE=/home/user/mtproto_config.txt
#   MTPROXY_STATS_DIR=/home/user/.mtproxy_stats
CONFIG_FILE="${MTPROXY_CONFIG_FILE:-${HOME}/mtproto_config.txt}"
STATEDIR="${MTPROXY_STATS_DIR:-${HOME}/.mtproxy_stats}"

# Under sudo, HOME may be /root: use the invoking user's home for state if ~/mtproto_config.txt exists there
if [[ -z "${MTPROXY_CONFIG_FILE:-}" && -z "${MTPROXY_STATS_DIR:-}" ]] &&
  [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
  _inv_home="$(getent passwd "$SUDO_UID" | cut -d: -f6)"
  if [[ -n "$_inv_home" && -f "$_inv_home/mtproto_config.txt" ]]; then
    CONFIG_FILE="$_inv_home/mtproto_config.txt"
    STATEDIR="$_inv_home/.mtproxy_stats"
  fi
fi

SESSIONS_FILE="${STATEDIR}/sessions.tsv"
PID_FILE="${STATEDIR}/collector.pid"

usage() {
  echo "Usage: $0 {report|collect|start|stop|status|diagnose|reset}"
  echo "  report    - table by client IP"
  echo "  collect   - foreground collector (default: poll conntrack -L; see MTPROXY_COLLECT_EVENTS)"
  echo "  start     - background, log ${STATEDIR}/collector.log"
  echo "  stop      - stop background collector"
  echo "  status    - is the collector running"
  echo "  diagnose  - paths, port, conntrack, hints if data is missing"
  echo "  reset trim|all [ -y ]  - see below"
  echo "Optional: MTPROXY_CONFIG_FILE, MTPROXY_STATS_DIR; MTPROXY_POLL_SEC (seconds, default 3);"
  echo "  MTPROXY_COLLECT_EVENTS=1 - legacy conntrack -E mode (often empty with Docker)."
  echo ""
  echo "Reset ${SESSIONS_FILE}:"
  echo "  $0 reset trim [ -y ]  - drop rows with Docker/127 IPs only (::ffff:172.16-31)"
  echo "  $0 reset all  [ -y ]  - backup and wipe file (all session history)"
  exit "${1:-0}"
}

cfg_get() {
  local key="$1"
  grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Missing ${CONFIG_FILE}. Configure the proxy first (start-mtproxy.sh -> 1)." >&2
    exit 1
  }
}

get_proxy_port() {
  require_config
  local p
  p="$(cfg_get PORT)"
  [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] || {
    echo "Config has no valid PORT=" >&2
    exit 1
  }
  echo "$p"
}

ensure_statedir() {
  mkdir -p "$STATEDIR"
  chmod 700 "$STATEDIR" 2>/dev/null || true
  : >>"$SESSIONS_FILE"
  chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
}

script_abspath() {
  local s="${BASH_SOURCE[0]}"
  [[ "$s" == */* ]] || s="./$s"
  (cd "$(dirname "$s")" && echo "$(pwd -P)/$(basename "$s")")
}

parse_conntrack_line() {
  local line="$1"
  local ev src sport dport lc
  lc="${line,,}"
  if [[ "$lc" =~ \[new\] ]]; then
    ev=NEW
  elif [[ "$lc" =~ \[destroy\] ]]; then
    ev=DESTROY
  else
    return 1
  fi
  [[ "$lc" =~ src=([^[:space:]]+) ]] || return 1
  src="${BASH_REMATCH[1]}"
  [[ "$lc" =~ sport=([0-9]+) ]] || return 1
  sport="${BASH_REMATCH[1]}"
  [[ "$lc" =~ dport=([0-9]+) ]] || return 1
  dport="${BASH_REMATCH[1]}"
  printf '%s\t%s\t%s\t%s\n' "$ev" "$src" "$sport" "$dport"
}

now_epoch() {
  date +%s 2>/dev/null
}

start_of_local_day() {
  if date -d 'today 0:00' +%s >/dev/null 2>&1; then
    date -d 'today 0:00' +%s
  else
    now_epoch
  fi
}

declare -A G_PENDING_START

# Skip typical Docker/bridge (172.16-31) or IPv4-mapped IPv6 (::ffff:...).
# Do not count these as proxy "clients".
skip_src_container_or_internal() {
  local s="${1,,}"
  [[ "$s" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^127\. ]] && return 0
  return 1
}

# First match src...dst...sport...dport=PORT in a conntrack -L line.
parse_list_line_client() {
  local line="$1" port="$2" lc
  lc="${line,,}"
  [[ "$lc" =~ src=([^[:space:]]+)[[:space:]]+dst=[^[:space:]]+[[:space:]]+sport=([0-9]+)[[:space:]]+dport=(${port})([^0-9]|$) ]] || return 1
  local src sport
  src="${BASH_REMATCH[1]}"
  sport="${BASH_REMATCH[2]}"
  skip_src_container_or_internal "$src" && return 1
  printf '%s\t%s\n' "$src" "$sport"
}

# Poll conntrack -L (more stable than -E behind NAT/Docker).
collect_poll_loop() {
  local proxy_port="$1"
  local poll_sec now key ip sport dur last
  poll_sec="${MTPROXY_POLL_SEC:-3}"
  [[ "$poll_sec" =~ ^[0-9]+$ ]] && ((poll_sec >= 1 && poll_sec <= 300)) || poll_sec=3
  declare -A active_last_seen
  echo "[stats-mtproxy] Polling conntrack -L every ${poll_sec}s, dport ${proxy_port} (ignoring src 172.16-31.*, 127.*, ::ffff:...)." >&2
  while true; do
    now="$(now_epoch)"
    declare -A seen=()
    while IFS= read -r line || true; do
      [[ -n "$line" ]] || continue
      parsed="$(parse_list_line_client "$line" "$proxy_port" 2>/dev/null)" || continue
      IFS=$'\t' read -r ip sport <<<"$parsed"
      key="${ip}|${sport}"
      seen["$key"]=1
      if [[ -n "${active_last_seen[$key]:-}" ]]; then
        last="${active_last_seen[$key]}"
        dur=$((now - last))
        if ((dur >= 1 && dur < 864000)); then
          mkdir -p "$STATEDIR"
          chmod 700 "$STATEDIR" 2>/dev/null || true
          printf '%s\t%s\t%s\t%s\n' "$last" "$now" "$ip" "$dur" >>"$SESSIONS_FILE"
        fi
      fi
      active_last_seen["$key"]="$now"
    done < <(conntrack -L -p tcp -n 2>/dev/null || true)

    local -a _keys
    _keys=("${!active_last_seen[@]}")
    for key in "${_keys[@]}"; do
      if [[ -z "${seen[$key]:-}" ]]; then
        unset 'active_last_seen[$key]'
      fi
    done
    sleep "$poll_sec"
  done
}

run_collect_pipe() {
  local proxy_port="$1"
  local line="$2"
  [[ -n "$line" ]] || return 0
  local parsed ev src sport dport key ts st dur
  parsed="$(parse_conntrack_line "$line" 2>/dev/null)" || return 0
  IFS=$'\t' read -r ev src sport dport <<<"$parsed"
  [[ "$dport" == "$proxy_port" ]] || return 0
  ts="$(now_epoch)"
  key="${src}_${sport}"
  case "$ev" in
    NEW)
      G_PENDING_START["$key"]="$ts"
      ;;
    DESTROY)
      st="${G_PENDING_START[$key]:-}"
      if [[ -n "$st" ]]; then
        ts="$(now_epoch)"
        dur=$((ts - st))
        if ((dur >= 0 && dur < 864000)); then
          mkdir -p "$STATEDIR"
          chmod 700 "$STATEDIR" 2>/dev/null || true
          printf '%s\t%s\t%s\t%s\n' "$st" "$ts" "$src" "$dur" >>"$SESSIONS_FILE"
        fi
        unset 'G_PENDING_START[$key]'
      fi
      ;;
  esac
}

collect_wrapper() {
  local proxy_port line
  proxy_port="$(get_proxy_port)"
  ensure_statedir
  command -v conntrack >/dev/null 2>&1 || {
    echo "conntrack not found. Install the package and load the kernel module if needed:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install -y conntrack" >&2
    echo "  Fedora/RHEL:   sudo dnf install -y conntrack-tools   # or: yum install conntrack-tools" >&2
    echo "  Module:        sudo modprobe nf_conntrack 2>/dev/null; lsmod | grep nf_conntrack" >&2
    echo "  conntrack often needs root: sudo $0 collect" >&2
    exit 1
  }
  echo "[stats-mtproxy] Host listen port: ${proxy_port}. Writing sessions to ${SESSIONS_FILE}" >&2
  if [[ -n "${MTPROXY_COLLECT_EVENTS:-}" ]]; then
    echo "[stats-mtproxy] conntrack -E mode (experimental)." >&2
    if command -v stdbuf >/dev/null 2>&1; then
      while IFS= read -r line; do
        run_collect_pipe "$proxy_port" "$line"
      done < <(stdbuf -oL conntrack -E -p tcp -o timestamp)
    else
      while IFS= read -r line; do
        run_collect_pipe "$proxy_port" "$line"
      done < <(conntrack -E -p tcp -o timestamp)
    fi
  else
    collect_poll_loop "$proxy_port"
  fi
}

start_background() {
  local proxy_port logf self pid
  proxy_port="$(get_proxy_port)"
  ensure_statedir
  logf="${STATEDIR}/collector.log"
  self="$(script_abspath)"
  command -v conntrack >/dev/null 2>&1 || {
    echo "Install conntrack (conntrack-tools), then run start again." >&2
    exit 1
  }
  if ! conntrack -L >/dev/null 2>&1; then
    echo "conntrack not accessible (need root / netlink). Run: sudo $0 start" >&2
    exit 1
  fi
  if [[ -f "$PID_FILE" ]]; then
    local old
    old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "Collector already running (PID $old)."
      exit 0
    fi
    rm -f "$PID_FILE"
  fi
  export SUDO_UID SUDO_USER PATH 2>/dev/null || true
  nohup env PATH="$PATH" bash "$self" collect >>"$logf" 2>&1 &
  pid=$!
  echo "$pid" >"$PID_FILE"
  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Collector exited immediately. Last lines of ${logf}:" >&2
    tail -n 25 "$logf" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "Hint: sudo $0 diagnose" >&2
    exit 1
  fi
  echo "Collector started, PID ${pid}, log: $logf (port ${proxy_port})"
}

stop_background() {
  [[ -f "$PID_FILE" ]] || {
    echo "PID file not found."
    exit 0
  }
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "Stopped PID $pid"
  else
    echo "Process not found."
  fi
  rm -f "$PID_FILE"
}

collector_status() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Collector running (PID $pid)"
      return 0
    fi
    if [[ -n "$pid" ]]; then
      echo "Collector not running (${PID_FILE} lists PID $pid but process is gone)."
    fi
  else
    echo "Collector not running (no ${PID_FILE})."
  fi
  return 1
}

diagnose_main() {
  (
    set +e
    set +o pipefail
    local proxy_port lines logf
    require_config || exit 1
    proxy_port="$(get_proxy_port)"
    logf="${STATEDIR}/collector.log"
    echo "======== stats-mtproxy diagnose ========"
    echo "CONFIG_FILE=${CONFIG_FILE}"
    echo "STATEDIR=${STATEDIR}"
    echo "PORT from config (host): ${proxy_port}"
    if [[ -f "$SESSIONS_FILE" ]]; then
      echo "sessions.tsv: ${SESSIONS_FILE} ($(wc -c <"$SESSIONS_FILE") bytes)"
    else
      echo "sessions.tsv: file does not exist yet"
    fi
    echo "EUID=${EUID:-} SUDO_UID=${SUDO_UID:-}"
    echo ""
    if command -v conntrack >/dev/null 2>&1; then
      if conntrack -L >/dev/null 2>&1; then
        echo "conntrack -L: OK"
        lines="$(conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | wc -l)"
        echo "conntrack entries with dport=${proxy_port} (now): ${lines}"
        echo "Sample (up to 8 lines with this dport):"
        conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | head -8 || echo "  (empty - no active TCP to this port or different field names)"
      else
        echo "conntrack -L: denied (need root). Run: sudo $0 diagnose"
      fi
    else
      echo "conntrack: command not found (apt install conntrack)"
    fi
    echo ""
    if command -v ss >/dev/null 2>&1; then
      echo "Listening on port ${proxy_port} (ss):"
      ss -tlnp 2>/dev/null | grep -E ":${proxy_port}\\s" || echo "  (no LISTEN on :${proxy_port} in ss output - check Docker -p)"
    fi
    echo ""
    if [[ -f "$logf" ]]; then
      echo "Tail of ${logf}:"
      tail -n 20 "$logf"
    else
      echo "Log ${logf} has not been created yet."
    fi
    echo ""
    echo "Collector polls conntrack -L by default (not -E); legacy mode: MTPROXY_COLLECT_EVENTS=1."
    echo "If the collector dies: sudo $0 start  (after conntrack-tools)."
    echo "Empty report: no inbound sessions on port ${proxy_port} after start (or only src 172.16-31 / 127.* - filtered out)."
    echo "========"
  )
}

fmt_duration() {
  local sec="${1:-0}"
  ((sec < 0)) && sec=0
  local h=$((sec / 3600))
  local m=$(((sec % 3600) / 60))
  printf '%dh %dm' "$h" "$m"
}

report_main() {
  require_config
  ensure_statedir
  local proxy_port now sod d7 d30 tmp
  proxy_port="$(get_proxy_port)"
  now="$(now_epoch)"
  sod="$(start_of_local_day)"
  d7=$((now - 7 * 86400))
  d30=$((now - 30 * 86400))

  if [[ ! -s "$SESSIONS_FILE" ]]; then
    echo ""
    echo "No data in ${SESSIONS_FILE} yet."
    echo "Start the collector (conntrack-tools) with the same paths as this report:"
    echo "  ./stats-mtproxy.sh start   or   sudo ./stats-mtproxy.sh start"
    echo "(under sudo, data goes to the invoking user's home if ~/mtproto_config.txt exists there)."
    echo "If you only ran sudo before without that behavior, stop the old process and start again."
    echo "Diagnostics: ./stats-mtproxy.sh diagnose   or   sudo ./stats-mtproxy.sh diagnose"
    collector_status || true
    echo ""
    return 0
  fi

  echo ""
  echo "Per-IP stats (proxy listen port on host: ${proxy_port})."
  echo "=================================================================================="

  tmp="$(mktemp)" || exit 1
  awk -v now="$now" -v sod="$sod" -v d7="$d7" -v d30="$d30" '
    function overlap(s, e, b0, b1, x, y) {
      if (e < b0 || s > b1) return 0
      x = s; if (b0 > x) x = b0
      y = e; if (b1 < y) y = b1
      if (y > x) return y - x
      return 0
    }
    NF >= 4 {
      s = $1 + 0; e = $2 + 0; ip = $3; dur = $4 + 0
      if (s > e || dur < 0) next
      if (ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      if (ip ~ /^127\./) next
      if (ip ~ /^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      first[ip] = (ip in first ? (s < first[ip] ? s : first[ip]) : s)
      total[ip] += dur
      today[ip] += overlap(s, e, sod, now)
      w7[ip] += overlap(s, e, d7, now)
      w30[ip] += overlap(s, e, d30, now)
    }
    END {
      for (ip in first)
        print ip "\t" first[ip] "\t" today[ip] "\t" w7[ip] "\t" w30[ip] "\t" total[ip]
    }
  ' "$SESSIONS_FILE" | sort -t $'\t' -k1 >"$tmp"

  printf '%-42s %-20s %12s %12s %12s %12s\n' \
    "IP" "First seen" "Today" "7 days" "30 days" "Total"

  local ip fts t d7c d30c tot ds
  while IFS=$'\t' read -r ip fts t d7c d30c tot; do
    if ds="$(date -d "@${fts}" '+%Y-%m-%d %H:%M' 2>/dev/null)"; then
      :
    else
      ds="$fts"
    fi
    printf '%-42s %-20s %12s %12s %12s %12s\n' \
      "$ip" "$ds" "$(fmt_duration "$t")" "$(fmt_duration "$d7c")" "$(fmt_duration "$d30c")" "$(fmt_duration "$tot")"
  done <"$tmp"
  rm -f "$tmp"

  echo "=================================================================================="
  collector_status || true
  echo ""
}

reset_stats_main() {
  require_config
  ensure_statedir
  local mode="" yes=0 a
  for a in "$@"; do
    case "$a" in
      trim | t) mode=trim ;;
      all | a) mode=all ;;
      -y | --yes) yes=1 ;;
      -h | --help)
        echo "reset trim [ -y ] - remove rows with internal IPs only (see README)."
        echo "reset all  [ -y ] - backup sessions.tsv and wipe it."
        return 0
        ;;
      *)
        echo "Unknown reset argument: $a" >&2
        echo "Use: $0 reset trim|all [ -y ]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$mode" ]] || {
    echo "Specify mode: $0 reset trim|all [ -y ]" >&2
    exit 1
  }
  if [[ ! -f "$SESSIONS_FILE" ]] || [[ ! -s "$SESSIONS_FILE" ]]; then
    echo "${SESSIONS_FILE} is empty or missing - nothing to reset."
    return 0
  fi
  if [[ "$yes" != 1 ]]; then
    local prompt
    if [[ "$mode" == trim ]]; then
      prompt="Remove from ${SESSIONS_FILE} only Docker/127 rows (backup .bak.timestamp)? [y/N] "
    else
      prompt="Backup and WIPE entire ${SESSIONS_FILE}? [y/N] "
    fi
    read -r -p "$prompt" _c || true
    [[ "${_c:-}" == y || "${_c:-}" == Y ]] || {
      echo "Cancelled."
      exit 0
    }
  fi
  local bak
  bak="${SESSIONS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$SESSIONS_FILE" "$bak" || {
    echo "Could not create backup ${bak}" >&2
    exit 1
  }
  echo "Backup: ${bak}"
  if [[ "$mode" == trim ]]; then
    awk 'NF >= 4 {
      ip = $3
      if (ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      if (ip ~ /^127\./) next
      if (ip ~ /^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      print
    }' "$bak" >"${SESSIONS_FILE}.tmp" && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Done: removed rows with filtered IPs."
  else
    : >"$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Done: file wiped."
  fi
}

main_cmd="${1:-}"
case "$main_cmd" in
  report) report_main ;;
  collect) collect_wrapper ;;
  start) start_background ;;
  stop) stop_background ;;
  status) collector_status ;;
  diagnose) diagnose_main ;;
  reset)
    shift
    reset_stats_main "$@"
    ;;
  -h | --help | help) usage 0 ;;
  *) usage 1 ;;
esac

