#!/usr/bin/env bash
# Сбор статистики по TCP к порту прокси на хосте (conntrack).
set -euo pipefail
# nohup/cron часто дают урезанный PATH — conntrack обычно в /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Явный переопределение (например под sudo):
#   MTPROXY_CONFIG_FILE=/home/user/mtproto_config.txt
#   MTPROXY_STATS_DIR=/home/user/.mtproxy_stats
CONFIG_FILE="${MTPROXY_CONFIG_FILE:-${HOME}/mtproto_config.txt}"
STATEDIR="${MTPROXY_STATS_DIR:-${HOME}/.mtproxy_stats}"

# Под sudo HOME=/root: кладём данные в домашний каталог того, кто вызвал sudo (если там конфиг прокси)
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
  echo "Использование: $0 {report|collect|start|stop|status|diagnose}"
  echo "  report    — таблица по IP"
  echo "  collect   — сборщик (по умолчанию опрос conntrack -L; см. MTPROXY_COLLECT_EVENTS)"
  echo "  start     — фон, лог ${STATEDIR}/collector.log"
  echo "  stop      — остановить фоновый сборщик"
  echo "  status    — запущен ли сборщик"
  echo "  diagnose  — пути, порт, conntrack, подсказки (если нет данных)"
  echo "Опционально: MTPROXY_CONFIG_FILE, MTPROXY_STATS_DIR; MTPROXY_POLL_SEC (сек, по умолчанию 3);"
  echo "  MTPROXY_COLLECT_EVENTS=1 — старый режим conntrack -E (с Docker часто пусто)."
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

# Первый «оригинальный» кортеж в строке conntrack -L (клиент → хост:порт прокси).
# Пропускаем src=172.17.* (исходящий трафик из контейнера Docker на :443).
parse_list_line_client() {
  local line="$1" port="$2" lc
  lc="${line,,}"
  [[ "$lc" =~ src=([^[:space:]]+)[[:space:]]+dst=[^[:space:]]+[[:space:]]+sport=([0-9]+)[[:space:]]+dport=(${port})([^0-9]|$) ]] || return 1
  local src sport
  src="${BASH_REMATCH[1]}"
  sport="${BASH_REMATCH[2]}"
  [[ "$src" =~ ^172\.17\. ]] && return 1
  printf '%s\t%s\n' "$src" "$sport"
}

# Опрос conntrack -L (стабильнее, чем -E, за NAT/Docker).
collect_poll_loop() {
  local proxy_port="$1"
  local poll_sec now ts key ip sport st dur
  poll_sec="${MTPROXY_POLL_SEC:-3}"
  [[ "$poll_sec" =~ ^[0-9]+$ ]] && ((poll_sec >= 1 && poll_sec <= 300)) || poll_sec=3
  declare -A active_start
  echo "[stats-mtproxy] Опрос conntrack -L каждые ${poll_sec}s, порт ${proxy_port} (игнор src 172.17.*)." >&2
  while true; do
    now="$(now_epoch)"
    declare -A seen=()
    while IFS= read -r line || true; do
      [[ -n "$line" ]] || continue
      parsed="$(parse_list_line_client "$line" "$proxy_port" 2>/dev/null)" || continue
      IFS=$'\t' read -r ip sport <<<"$parsed"
      key="${ip}|${sport}"
      seen["$key"]=1
      if [[ -z "${active_start[$key]:-}" ]]; then
        active_start["$key"]="$now"
      fi
    done < <(conntrack -L -p tcp -n 2>/dev/null || true)

    local -a _keys
    _keys=("${!active_start[@]}")
    for key in "${_keys[@]}"; do
      if [[ -z "${seen[$key]:-}" ]]; then
        st="${active_start[$key]}"
        ip="${key%%|*}"
        sport="${key##*|}"
        dur=$((now - st))
        if ((dur >= 1 && dur < 864000)); then
          mkdir -p "$STATEDIR"
          chmod 700 "$STATEDIR" 2>/dev/null || true
          printf '%s\t%s\t%s\t%s\n' "$st" "$now" "$ip" "$dur" >>"$SESSIONS_FILE"
        fi
        unset 'active_start[$key]'
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
    echo "Не найдена команда conntrack. Установите пакет и при необходимости загрузите модуль ядра:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install -y conntrack" >&2
    echo "  Fedora/RHEL:   sudo dnf install -y conntrack-tools   # или: yum install conntrack-tools" >&2
    echo "  Модуль:        sudo modprobe nf_conntrack 2>/dev/null; lsmod | grep nf_conntrack" >&2
    echo "  События conntrack часто требуют root: sudo $0 collect" >&2
    exit 1
  }
  echo "[stats-mtproxy] Порт хоста: ${proxy_port}. Пишем сессии в ${SESSIONS_FILE}" >&2
  if [[ -n "${MTPROXY_COLLECT_EVENTS:-}" ]]; then
    echo "[stats-mtproxy] Режим conntrack -E (экспериментально)." >&2
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
    echo "Установите conntrack (conntrack-tools), затем повторите start." >&2
    exit 1
  }
  if ! conntrack -L >/dev/null 2>&1; then
    echo "conntrack недоступен (нужны права root / netlink). Запустите: sudo $0 start" >&2
    exit 1
  fi
  if [[ -f "$PID_FILE" ]]; then
    local old
    old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "Сборщик уже запущен (PID $old)."
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
    echo "Сборщик сразу завершился. Последние строки ${logf}:" >&2
    tail -n 25 "$logf" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "Подсказка: sudo $0 diagnose" >&2
    exit 1
  fi
  echo "Сборщик запущен, PID ${pid}, лог: $logf (порт ${proxy_port})"
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
    if [[ -n "$pid" ]]; then
      echo "Сборщик не запущен (в ${PID_FILE} записан PID $pid — процесс завершился)."
    fi
  else
    echo "Сборщик не запущен (нет ${PID_FILE})."
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
    echo "──────── stats-mtproxy diagnose ────────"
    echo "CONFIG_FILE=${CONFIG_FILE}"
    echo "STATEDIR=${STATEDIR}"
    echo "PORT из конфига (хост): ${proxy_port}"
    if [[ -f "$SESSIONS_FILE" ]]; then
      echo "sessions.tsv: ${SESSIONS_FILE} ($(wc -c <"$SESSIONS_FILE") байт)"
    else
      echo "sessions.tsv: файла ещё нет"
    fi
    echo "EUID=${EUID:-} SUDO_UID=${SUDO_UID:-}"
    echo ""
    if command -v conntrack >/dev/null 2>&1; then
      if conntrack -L >/dev/null 2>&1; then
        echo "conntrack -L: OK"
        lines="$(conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | wc -l)"
        echo "Записей conntrack с dport=${proxy_port} (сейчас): ${lines}"
        echo "Пример (до 8 строк с этим dport):"
        conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | head -8 || echo "  (пусто — нет активных TCP на этот порт или другое имя полей)"
      else
        echo "conntrack -L: отказ (нужен root). Запуск: sudo $0 diagnose"
      fi
    else
      echo "conntrack: команда не найдена (apt install conntrack)"
    fi
    echo ""
    if command -v ss >/dev/null 2>&1; then
      echo "Прослушивание порта ${proxy_port} (ss):"
      ss -tlnp 2>/dev/null | grep -E ":${proxy_port}\\s" || echo "  (нет LISTEN на :${proxy_port} в выводе ss — проверьте Docker -p)"
    fi
    echo ""
    if [[ -f "$logf" ]]; then
      echo "Хвост ${logf}:"
      tail -n 20 "$logf"
    else
      echo "Лог ${logf} ещё не создавался."
    fi
    echo ""
    echo "Сборщик по умолчанию опрашивает conntrack -L (не -E); старый режим: MTPROXY_COLLECT_EVENTS=1."
    echo "Если сборщик падает: sudo $0 start  (после conntrack-tools)."
    echo "Пустой отчёт: нет входящих сессий на порт ${proxy_port} после start (или только исход 172.17.* — они отфильтрованы)."
    echo "────────"
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
    echo "Пока нет записей в ${SESSIONS_FILE}."
    echo "Запустите сборщик (conntrack-tools), с теми же путями, что и отчёт:"
    echo "  ./stats-mtproxy.sh start   или   sudo ./stats-mtproxy.sh start"
    echo "(под sudo данные пишутся в домашний каталог пользователя, если есть ~/mtproto_config.txt)."
    echo "Если ранее запускали только sudo без этого поведения — остановите старый процесс и запустите start заново."
    echo "Диагностика: ./stats-mtproxy.sh diagnose   или   sudo ./stats-mtproxy.sh diagnose"
    collector_status || true
    echo ""
    return 0
  fi

  echo ""
  echo "Статистика по IP (порт прокси на хосте: ${proxy_port})."
  echo "────────────────────────────────────────────────────────────────────────────────────────"

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

  printf '%-42s %-20s %12s %12s %12s %12s\n' \
    "IP" "Первое соединение" "Сегодня" "7 дней" "30 дней" "Всего"

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

  echo "────────────────────────────────────────────────────────────────────────────────────────"
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
  diagnose) diagnose_main ;;
  -h | --help | help) usage 0 ;;
  *) usage 1 ;;
esac
