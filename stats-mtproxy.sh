#!/usr/bin/env bash
# Сбор статистики TCP-сессий к порту прокси на хосте (conntrack).
set -euo pipefail
# В nohup/cron PATH часто урезан; conntrack обычно лежит в /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Явные переопределения (например, под sudo):
#   MTPROXY_CONFIG_FILE=/home/user/mtproto_config.txt
#   MTPROXY_STATS_DIR=/home/user/.mtproxy_stats
CONFIG_FILE="${MTPROXY_CONFIG_FILE:-${HOME}/mtproto_config.txt}"
STATEDIR="${MTPROXY_STATS_DIR:-${HOME}/.mtproxy_stats}"

# Под sudo HOME может быть /root: используем домашний каталог вызывавшего пользователя,
# если там есть ~/mtproto_config.txt
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
  echo "Использование: $0 {report|collect|start|stop|status|diagnose|reset}"
  echo "  report    - таблица по IP клиентов"
  echo "  collect   - сборщик в foreground (по умолчанию: опрос conntrack -L; см. MTPROXY_COLLECT_EVENTS)"
  echo "  start     - запуск в фоне, лог ${STATEDIR}/collector.log"
  echo "  stop      - остановить фоновый сборщик"
  echo "  status    - запущен ли сборщик"
  echo "  diagnose  - пути, порт, conntrack, подсказки при отсутствии данных"
  echo "  reset trim|all [ -y ]  - см. ниже"
  echo "Опционально: MTPROXY_CONFIG_FILE, MTPROXY_STATS_DIR; MTPROXY_POLL_SEC (секунды, по умолчанию 3);"
  echo "  MTPROXY_COLLECT_EVENTS=1 - старый режим conntrack -E (с Docker часто пусто)."
  echo "  MTPROXY_LOCAL_IPS=\"a b\" - явный список локальных IPv4 для conntrack."
  echo "  MTPROXY_NO_SS=1 - не опрашивать ss (только conntrack)."
  echo ""
  echo "Сброс ${SESSIONS_FILE}:"
  echo "  $0 reset trim [ -y ]  - удалить только строки с Docker/127 IP (::ffff:172.16-31)"
  echo "  $0 reset all  [ -y ]  - сделать бэкап и очистить файл (вся история сессий)"
  exit "${1:-0}"
}

cfg_get() {
  local key="$1"
  grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Не найден ${CONFIG_FILE}. Сначала настройте прокси (start-mtproxy.sh -> 1)." >&2
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

get_proxy_server_ip() {
  require_config
  local s
  s="$(cfg_get SERVER)"
  [[ -n "$s" ]] || return 1
  echo "$s"
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

# Пропускаем служебные адреса Docker/bridge (172.16-31, 172.17) и IPv4 в IPv6 (::ffff:...).
# Такие источники не считаем клиентами прокси.
skip_src_container_or_internal() {
  local s="${1,,}"
  [[ "$s" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^172\.17\. ]] && return 0
  [[ "$s" =~ ^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^127\. ]] && return 0
  return 1
}

# Собираем множество локальных IPv4 адресов хоста, чтобы отличать входящие соединения
# к опубликованному порту прокси от исходящих соединений прокси к внешним IP:443.
#
# Порядок:
# - MTPROXY_LOCAL_IPS="ip1 ip2 ..." (если задано)
# - ip -o -4 addr show scope global (если доступно)
# - SERVER из mtproto_config.txt (как запасной вариант)
declare -a G_LOCAL_IPV4S=()
load_local_ipv4s() {
  local x
  G_LOCAL_IPV4S=()
  if [[ -n "${MTPROXY_LOCAL_IPS:-}" ]]; then
    # shellcheck disable=SC2206
    G_LOCAL_IPV4S=(${MTPROXY_LOCAL_IPS})
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r x || [[ -n "$x" ]]; do
      [[ -n "$x" ]] || continue
      G_LOCAL_IPV4S+=("$x")
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [[ "${#G_LOCAL_IPV4S[@]}" -gt 0 ]] && return 0
  fi
  if x="$(get_proxy_server_ip 2>/dev/null)"; then
    [[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && G_LOCAL_IPV4S+=("$x")
  fi
  return 0
}

is_local_ipv4() {
  local ip="$1" x
  for x in "${G_LOCAL_IPV4S[@]}"; do
    [[ "$ip" == "$x" ]] && return 0
  done
  return 1
}

# Берём кортеж клиента из строки conntrack -L.
# Считаем "клиентом" только входящее соединение, где dst=<локальный IP хоста> и dport=PORT.
parse_list_line_client() {
  local line="$1" port="$2" lc
  lc="${line,,}"
  [[ "$lc" =~ src=([^[:space:]]+)[[:space:]]+dst=([^[:space:]]+)[[:space:]]+sport=([0-9]+)[[:space:]]+dport=(${port})([^0-9]|$) ]] || return 1
  local src dst sport
  src="${BASH_REMATCH[1]}"
  dst="${BASH_REMATCH[2]}"
  sport="${BASH_REMATCH[3]}"
  is_local_ipv4 "$dst" || return 1
  skip_src_container_or_internal "$src" && return 1
  printf '%s\t%s\n' "$src" "$sport"
}

# Пиры ESTAB к локальному :PORT (docker-proxy при -p 443:443). По одной строке: ip<TAB>sport
list_ss_established_peers_on_port() {
  local port="$1"
  local local_a peer lp ip sport
  [[ -n "$port" ]] || return 0
  command -v ss >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r local_a peer || [[ -n "$local_a" ]]; do
    [[ -n "$local_a" ]] || continue
    lp="${local_a##*:}"
    [[ "$lp" == "$port" ]] || continue
    [[ -n "$peer" ]] || continue
    if [[ "$peer" =~ ^\[([^]]+)\]:(.+)$ ]]; then
      ip="[${BASH_REMATCH[1]}]"
      sport="${BASH_REMATCH[2]}"
    else
      ip="${peer%:*}"
      sport="${peer##*:}"
    fi
    [[ -n "$ip" && -n "$sport" ]] || continue
    printf '%s\t%s\n' "$ip" "$sport"
  done < <(ss -tn state established 2>/dev/null | awk '$1 ~ /^ESTAB/ {print $4 "\t" $5}')
}

append_session_row() {
  local st="$1" en="$2" ip="$3"
  # Для очень коротких потоков (попали в один снимок опроса) en может быть == st.
  # Записываем минимум 1 секунду, чтобы такие сессии не терялись.
  if ((en <= st)); then
    en=$((st + 1))
  fi
  local dur=$((en - st))
  if ((dur >= 1 && dur < 864000)); then
    mkdir -p "$STATEDIR"
    chmod 700 "$STATEDIR" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$st" "$en" "$ip" "$dur" >>"$SESSIONS_FILE"
  fi
}

# Опрос conntrack -L (стабильнее, чем -E, за NAT/Docker).
collect_poll_loop() {
  local proxy_port="$1"
  local poll_sec now
  poll_sec="${MTPROXY_POLL_SEC:-3}"
  [[ "$poll_sec" =~ ^[0-9]+$ ]] && ((poll_sec >= 1 && poll_sec <= 300)) || poll_sec=3
  declare -A active_first_seen
  declare -A active_last_seen
  load_local_ipv4s || true
  echo "[stats-mtproxy] Опрос каждые ${poll_sec}с: conntrack -L + ss ESTAB на :${proxy_port} (локальные IP для ct: ${G_LOCAL_IPV4S[*]:-?}; без ss: MTPROXY_NO_SS=1)." >&2
  while true; do
    now="$(now_epoch)"
    declare -A seen=()
    # Без «|| true» при EOF цикл не завершался (вечное вращение после conntrack -L).
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      parsed="$(parse_list_line_client "$line" "$proxy_port" 2>/dev/null)" || continue
      IFS=$'\t' read -r ip sport <<<"$parsed"
      key="${ip}|${sport}"
      seen["$key"]=1
      [[ -n "${active_first_seen[$key]:-}" ]] || active_first_seen["$key"]="$now"
      active_last_seen["$key"]="$now"
    done < <(conntrack -L -p tcp -n 2>/dev/null || true)

    if [[ -z "${MTPROXY_NO_SS:-}" ]]; then
      while IFS=$'\t' read -r ip sport || [[ -n "$ip" ]]; do
        [[ -n "$ip" ]] || continue
        skip_src_container_or_internal "$ip" && continue
        key="${ip}|${sport}"
        seen["$key"]=1
        [[ -n "${active_first_seen[$key]:-}" ]] || active_first_seen["$key"]="$now"
        active_last_seen["$key"]="$now"
      done < <(list_ss_established_peers_on_port "$proxy_port")
    fi

    local -a _keys
    _keys=("${!active_last_seen[@]}")
    for key in "${_keys[@]}"; do
      if [[ -z "${seen[$key]:-}" ]]; then
        st="${active_first_seen[$key]:-}"
        # Закрываем сессию моментом текущего опроса: так учитываются и короткие
        # потоки, которые успели попасть только в один снимок conntrack/ss.
        if [[ -n "$st" ]]; then
          ip="${key%|*}"
          append_session_row "$st" "$now" "$ip"
        fi
        unset 'active_last_seen[$key]'
        unset 'active_first_seen[$key]'
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
  # Если сборщик завершится (ошибка, сигнал, OOM-kill и т.п.), запишем причину в лог.
  # Это особенно важно при запуске через start (nohup), где иначе видно только «процесс умер».
  trap 'rc=$?; echo "[stats-mtproxy] Сборщик завершился: rc=${rc}, line=${BASH_LINENO[0]}, cmd=${BASH_COMMAND}" >&2' EXIT
  command -v conntrack >/dev/null 2>&1 || {
    echo "Команда conntrack не найдена. Установите пакет и при необходимости загрузите модуль ядра:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install -y conntrack" >&2
    echo "  Fedora/RHEL:   sudo dnf install -y conntrack-tools   # или: yum install conntrack-tools" >&2
    echo "  Модуль:        sudo modprobe nf_conntrack 2>/dev/null; lsmod | grep nf_conntrack" >&2
    echo "  conntrack часто требует root: sudo $0 collect" >&2
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
    echo "conntrack недоступен (нужны root-права / netlink). Запустите: sudo $0 start" >&2
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
    echo "Сборщик завершился сразу. Последние строки ${logf}:" >&2
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
    if [[ -n "$pid" ]] && { kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; }; then
      echo "Сборщик работает (PID $pid)"
      return 0
    fi
    if [[ -n "$pid" ]]; then
      echo "Сборщик не запущен (в ${PID_FILE} указан PID $pid, но процесс уже завершён)."
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
    echo "======== Диагностика stats-mtproxy ========"
    echo "CONFIG_FILE=${CONFIG_FILE}"
    echo "STATEDIR=${STATEDIR}"
    echo "PORT из конфига (хост): ${proxy_port}"
    if [[ -f "$SESSIONS_FILE" ]]; then
      echo "sessions.tsv: ${SESSIONS_FILE} ($(wc -c <"$SESSIONS_FILE") байт)"
    else
      echo "sessions.tsv: файла пока нет"
    fi
    echo "EUID=${EUID:-} SUDO_UID=${SUDO_UID:-}"
    echo ""
    if command -v conntrack >/dev/null 2>&1; then
      if conntrack -L >/dev/null 2>&1; then
        echo "conntrack -L: OK"
        lines="$(conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | wc -l)"
        echo "Записей conntrack с dport=${proxy_port} (сейчас): ${lines}"
        echo "Пример (до 8 строк с этим dport):"
        conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | head -8 || echo "  (пусто - нет активных TCP на этот порт или иные имена полей)"
      else
        echo "conntrack -L: отказ (нужен root). Запуск: sudo $0 diagnose"
      fi
    else
      echo "conntrack: команда не найдена (apt install conntrack)"
    fi
    echo ""
    if command -v ss >/dev/null 2>&1; then
      echo "Прослушивание порта ${proxy_port} (ss):"
      ss -tlnp 2>/dev/null | grep -E ":${proxy_port}\\s" || echo "  (нет LISTEN на :${proxy_port} в ss - проверьте Docker -p)"
      lines="$(ss -tn state established 2>/dev/null | awk -v p=":${proxy_port}" '$1 ~ /^ESTAB/ && index($4,p)>0 {c++} END{print c+0}')"
      echo "ESTAB к локальному *:${proxy_port} (ss, для docker-proxy): ${lines}"
      echo "Пример (до 6 строк):"
      ss -tn state established 2>/dev/null | awk -v p=":${proxy_port}" '$1 ~ /^ESTAB/ && index($4,p)>0 {print; if(++n>=6) exit}' || echo "  (пусто)"
    fi
    echo ""
    if [[ -f "$logf" ]]; then
      echo "Хвост ${logf}:"
      tail -n 20 "$logf"
    else
      echo "Лог ${logf} ещё не создан."
    fi
    echo ""
    echo "По умолчанию сборщик опрашивает conntrack -L (не -E); старый режим: MTPROXY_COLLECT_EVENTS=1."
    echo "Если сборщик падает: sudo $0 start  (после установки conntrack-tools)."
    echo "Пустой отчёт: нет входящих сессий на порт ${proxy_port} после start, или conntrack показывает только исходящие из контейнера (тогда смотрите ss ESTAB выше; сборщик объединяет conntrack + ss)."
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
    echo "В ${SESSIONS_FILE} пока нет данных."
    local _rpid
    if [[ -f "$PID_FILE" ]]; then
      _rpid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if [[ -n "$_rpid" ]] && ! { kill -0 "$_rpid" 2>/dev/null || ps -p "$_rpid" >/dev/null 2>&1; }; then
        echo "Сборщик упал: в ${PID_FILE} указан PID ${_rpid}, но процесс уже нет."
        echo "См. лог: tail -50 ${STATEDIR}/collector.log"
        echo "Очистите PID и перезапустите: sudo $0 stop 2>/dev/null; sudo $0 start"
      fi
    fi
    echo "Запустите сборщик (conntrack-tools) с теми же путями, что и для отчёта:"
    echo "  ./stats-mtproxy.sh start   или   sudo ./stats-mtproxy.sh start"
    echo "(под sudo данные пишутся в домашний каталог вызывавшего пользователя, если там есть ~/mtproto_config.txt)."
    echo "Если раньше запускали только sudo без этого поведения — остановите старый процесс и запустите start заново."
    echo "Диагностика: ./stats-mtproxy.sh diagnose   или   sudo ./stats-mtproxy.sh diagnose"
    collector_status || true
    echo ""
    return 0
  fi

  echo ""
  echo "Статистика по IP (порт прокси на хосте: ${proxy_port})."
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
    "IP" "Первое подключение" "Сегодня" "7 дней" "30 дней" "Всего"

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
        echo "reset trim [ -y ] - удалить строки со служебными IP (см. README)."
        echo "reset all  [ -y ] - сделать бэкап sessions.tsv и очистить файл."
        return 0
        ;;
      *)
        echo "Неизвестный аргумент reset: $a" >&2
        echo "Используйте: $0 reset trim|all [ -y ]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$mode" ]] || {
    echo "Укажите режим: $0 reset trim|all [ -y ]" >&2
    exit 1
  }
  if [[ ! -f "$SESSIONS_FILE" ]] || [[ ! -s "$SESSIONS_FILE" ]]; then
    echo "${SESSIONS_FILE} пуст или отсутствует - сбрасывать нечего."
    return 0
  fi
  if [[ "$yes" != 1 ]]; then
    local prompt
    if [[ "$mode" == trim ]]; then
      prompt="Удалить из ${SESSIONS_FILE} только строки Docker/127 (с бэкапом .bak.timestamp)? [y/N] "
    else
      prompt="Сделать бэкап и ПОЛНОСТЬЮ ОЧИСТИТЬ ${SESSIONS_FILE}? [y/N] "
    fi
    read -r -p "$prompt" _c || true
    [[ "${_c:-}" == y || "${_c:-}" == Y ]] || {
      echo "Отменено."
      exit 0
    }
  fi
  local bak
  bak="${SESSIONS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$SESSIONS_FILE" "$bak" || {
    echo "Не удалось создать бэкап ${bak}" >&2
    exit 1
  }
  echo "Бэкап: ${bak}"
  if [[ "$mode" == trim ]]; then
    awk 'NF >= 4 {
      ip = $3
      if (ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      if (ip ~ /^127\./) next
      if (ip ~ /^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      print
    }' "$bak" >"${SESSIONS_FILE}.tmp" && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Готово: строки с отфильтрованными IP удалены."
  else
    : >"$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Готово: файл очищен."
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

