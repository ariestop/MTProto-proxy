#!/usr/bin/env bash
# Сбор статистики по TCP к порту прокси на хосте (conntrack).
# Устройство / имя устройства MTProto-прокси не видит (шифрование).
set -euo pipefail

CONFIG_FILE="${HOME}/mtproto_config.txt"
STATEDIR="${HOME}/.mtproxy_stats"
SESSIONS_FILE="${STATEDIR}/sessions.tsv"
PID_FILE="${STATEDIR}/collector.pid"

usage() {
  echo "Использование: $0 {report|collect|start|stop|status}"
  echo "  report  — таблица по IP"
  echo "  collect — слушать conntrack (foreground)"
  echo "  start   — фон, лог ${STATEDIR}/collector.log"
  echo "  stop    — остановить фоновый сборщик"
  echo "  status  — запущен ли сборщик"
  exit "${1:-0}"
}

cfg_get() {
  local key="$1"
  grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Нет ${CONFIG_FILE}. Сначала установите прокси (start-mtproxy.sh → 1)." >&2
    exit 1
  }
}

get_proxy_port() {
  require_config
  local p
  p="$(cfg_get PORT)"
  [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] || {
    echo "В конфиге нет корректного PORT=" >&2
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
  local ev src sport dport
  [[ "$line" =~ \[([A-Z]+)\] ]] || return 1
  ev="${BASH_REMATCH[1]}"
  [[ "$ev" == NEW || "$ev" == DESTROY ]] || return 1
  [[ "$line" =~ src=([^[:space:]]+) ]] || return 1
  src="${BASH_REMATCH[1]}"
  [[ "$line" =~ sport=([0-9]+) ]] || return 1
  sport="${BASH_REMATCH[1]}"
  [[ "$line" =~ dport=([0-9]+) ]] || return 1
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
    echo "Нужна команда conntrack (пакет conntrack-tools), модуль nf_conntrack." >&2
    exit 1
  }
  echo "[mtproxy-stats] Порт хоста: ${proxy_port}. Пишем сессии в ${SESSIONS_FILE}" >&2
  # Без подпроцесса в пайпе — иначе теряется G_PENDING_START
  if command -v stdbuf >/dev/null 2>&1; then
    while IFS= read -r line; do
      run_collect_pipe "$proxy_port" "$line"
    done < <(stdbuf -oL conntrack -E -p tcp -o timestamp 2>/dev/null)
  else
    while IFS= read -r line; do
      run_collect_pipe "$proxy_port" "$line"
    done < <(conntrack -E -p tcp -o timestamp 2>/dev/null)
  fi
}

start_background() {
  local proxy_port logf self
  proxy_port="$(get_proxy_port)"
  ensure_statedir
  logf="${STATEDIR}/collector.log"
  self="$(script_abspath)"
  if [[ -f "$PID_FILE" ]]; then
    local old
    old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "Сборщик уже запущен (PID $old)."
      exit 0
    fi
    rm -f "$PID_FILE"
  fi
  nohup bash "$self" collect >>"$logf" 2>&1 &
  echo $! >"$PID_FILE"
  echo "Сборщик запущен, PID $(cat "$PID_FILE"), лог: $logf (порт ${proxy_port})"
}

stop_background() {
  [[ -f "$PID_FILE" ]] || {
    echo "PID-файл не найден."
    exit 0
  }
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "Остановлен PID $pid"
  else
    echo "Процесс не найден."
  fi
  rm -f "$PID_FILE"
}

collector_status() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Сборщик работает (PID $pid)"
      return 0
    fi
  fi
  echo "Сборщик не запущен."
  return 1
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
    echo "Пока нет записей в ${SESSIONS_FILE}."
    echo "На Linux-сервере: chmod +x mtproxy-stats.sh && ./mtproxy-stats.sh start"
    echo "Нужны conntrack-tools; учёт с момента запуска сборщика."
    collector_status || true
    echo ""
    return 0
  fi

  echo ""
  echo "Статистика по IP (порт прокси на хосте: ${proxy_port})."
  echo "Устройство / имя: н/д — MTProto не раскрывает клиент. Один IP может быть NAT."
  echo "────────────────────────────────────────────────────────────────────────────────────────────────────"

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

  printf '%-42s %-20s %-6s %-6s %12s %12s %12s %12s\n' \
    "IP" "Первое соединение" "Устр." "Имя" "Сегодня" "7 дней" "30 дней" "Всего"

  local ip fts t d7c d30c tot ds
  while IFS=$'\t' read -r ip fts t d7c d30c tot; do
    if ds="$(date -d "@${fts}" '+%Y-%m-%d %H:%M' 2>/dev/null)"; then
      :
    else
      ds="$fts"
    fi
    printf '%-42s %-20s %-6s %-6s %12s %12s %12s %12s\n' \
      "$ip" "$ds" "н/д" "н/д" "$(fmt_duration "$t")" "$(fmt_duration "$d7c")" "$(fmt_duration "$d30c")" "$(fmt_duration "$tot")"
  done <"$tmp"
  rm -f "$tmp"

  echo "────────────────────────────────────────────────────────────────────────────────────────────────────"
  collector_status || true
  echo ""
}

main_cmd="${1:-}"
case "$main_cmd" in
  report) report_main ;;
  collect) collect_wrapper ;;
  start) start_background ;;
  stop) stop_background ;;
  status) collector_status ;;
  -h | --help | help) usage 0 ;;
  *) usage 1 ;;
esac
