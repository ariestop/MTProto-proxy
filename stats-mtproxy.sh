#!/usr/bin/env bash
# РЎР±РѕСЂ СЃС‚Р°С‚РёСЃС‚РёРєРё РїРѕ TCP Рє РїРѕСЂС‚Сѓ РїСЂРѕРєСЃРё РЅР° С…РѕСЃС‚Рµ (conntrack).
set -euo pipefail
# nohup/cron С‡Р°СЃС‚Рѕ РґР°СЋС‚ СѓСЂРµР·Р°РЅРЅС‹Р№ PATH вЂ” conntrack РѕР±С‹С‡РЅРѕ РІ /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# РЇРІРЅС‹Р№ РїРµСЂРµРѕРїСЂРµРґРµР»РµРЅРёРµ (РЅР°РїСЂРёРјРµСЂ РїРѕРґ sudo):
#   MTPROXY_CONFIG_FILE=/home/user/mtproto_config.txt
#   MTPROXY_STATS_DIR=/home/user/.mtproxy_stats
CONFIG_FILE="${MTPROXY_CONFIG_FILE:-${HOME}/mtproto_config.txt}"
STATEDIR="${MTPROXY_STATS_DIR:-${HOME}/.mtproxy_stats}"

# РџРѕРґ sudo HOME=/root: РєР»Р°РґС‘Рј РґР°РЅРЅС‹Рµ РІ РґРѕРјР°С€РЅРёР№ РєР°С‚Р°Р»РѕРі С‚РѕРіРѕ, РєС‚Рѕ РІС‹Р·РІР°Р» sudo (РµСЃР»Рё С‚Р°Рј РєРѕРЅС„РёРі РїСЂРѕРєСЃРё)
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
  echo "РСЃРїРѕР»СЊР·РѕРІР°РЅРёРµ: $0 {report|collect|start|stop|status|diagnose|reset}"
  echo "  report    вЂ” С‚Р°Р±Р»РёС†Р° РїРѕ IP"
  echo "  collect   вЂ” СЃР±РѕСЂС‰РёРє (РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ РѕРїСЂРѕСЃ conntrack -L; СЃРј. MTPROXY_COLLECT_EVENTS)"
  echo "  start     вЂ” С„РѕРЅ, Р»РѕРі ${STATEDIR}/collector.log"
  echo "  stop      вЂ” РѕСЃС‚Р°РЅРѕРІРёС‚СЊ С„РѕРЅРѕРІС‹Р№ СЃР±РѕСЂС‰РёРє"
  echo "  status    вЂ” Р·Р°РїСѓС‰РµРЅ Р»Рё СЃР±РѕСЂС‰РёРє"
  echo "  diagnose  вЂ” РїСѓС‚Рё, РїРѕСЂС‚, conntrack, РїРѕРґСЃРєР°Р·РєРё (РµСЃР»Рё РЅРµС‚ РґР°РЅРЅС‹С…)"
  echo "  reset trim|all [ -y ]  вЂ” СЃРј. РЅРёР¶Рµ"
  echo "РћРїС†РёРѕРЅР°Р»СЊРЅРѕ: MTPROXY_CONFIG_FILE, MTPROXY_STATS_DIR; MTPROXY_POLL_SEC (СЃРµРє, РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ 3);"
  echo "  MTPROXY_COLLECT_EVENTS=1 вЂ” СЃС‚Р°СЂС‹Р№ СЂРµР¶РёРј conntrack -E (СЃ Docker С‡Р°СЃС‚Рѕ РїСѓСЃС‚Рѕ)."
  echo ""
  echo "РЎР±СЂРѕСЃ ${SESSIONS_FILE}:"
  echo "  $0 reset trim [ -y ]  вЂ” СѓРґР°Р»РёС‚СЊ С‚РѕР»СЊРєРѕ СЃС‚СЂРѕРєРё СЃ IP Docker/127 (::ffff:172.16вЂ“31)"
  echo "  $0 reset all  [ -y ]  вЂ” Р±СЌРєР°Рї Рё РїСѓСЃС‚РѕР№ С„Р°Р№Р» (РІСЃСЏ РёСЃС‚РѕСЂРёСЏ СЃРµСЃСЃРёР№)"
  exit "${1:-0}"
}

cfg_get() {
  local key="$1"
  grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "РќРµС‚ ${CONFIG_FILE}. РЎРЅР°С‡Р°Р»Р° СѓСЃС‚Р°РЅРѕРІРёС‚Рµ РїСЂРѕРєСЃРё (start-mtproxy.sh в†’ 1)." >&2
    exit 1
  }
}

get_proxy_port() {
  require_config
  local p
  p="$(cfg_get PORT)"
  [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] || {
    echo "Р’ РєРѕРЅС„РёРіРµ РЅРµС‚ РєРѕСЂСЂРµРєС‚РЅРѕРіРѕ PORT=" >&2
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

# РСЃС‚РѕС‡РЅРёРє вЂ” С‚РёРїРёС‡РЅС‹Р№ Р°РґСЂРµСЃ Docker/bridge (172.16вЂ“31) РёР»Рё IPv4 РІ IPv6 (::ffff:вЂ¦).
# РќРµ СЃС‡РёС‚Р°РµРј В«Р°Р±РѕРЅРµРЅС‚РѕРјВ» РїСЂРѕРєСЃРё.
skip_src_container_or_internal() {
  local s="${1,,}"
  [[ "$s" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$s" =~ ^127\. ]] && return 0
  return 1
}

# РџРµСЂРІС‹Р№ РєРѕСЂС‚РµР¶ srcвЂ¦dstвЂ¦sportвЂ¦dport=PORT РІ СЃС‚СЂРѕРєРµ conntrack -L.
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

# РћРїСЂРѕСЃ conntrack -L (СЃС‚Р°Р±РёР»СЊРЅРµРµ, С‡РµРј -E, Р·Р° NAT/Docker).
collect_poll_loop() {
  local proxy_port="$1"
  local poll_sec now key ip sport dur last
  poll_sec="${MTPROXY_POLL_SEC:-3}"
  [[ "$poll_sec" =~ ^[0-9]+$ ]] && ((poll_sec >= 1 && poll_sec <= 300)) || poll_sec=3
  declare -A active_last_seen
  echo "[stats-mtproxy] РћРїСЂРѕСЃ conntrack -L РєР°Р¶РґС‹Рµ ${poll_sec}s, РїРѕСЂС‚ ${proxy_port} (РёРіРЅРѕСЂ src 172.16вЂ“31.*, 127.*, ::ffff:вЂ¦)." >&2
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
    echo "РќРµ РЅР°Р№РґРµРЅР° РєРѕРјР°РЅРґР° conntrack. РЈСЃС‚Р°РЅРѕРІРёС‚Рµ РїР°РєРµС‚ Рё РїСЂРё РЅРµРѕР±С…РѕРґРёРјРѕСЃС‚Рё Р·Р°РіСЂСѓР·РёС‚Рµ РјРѕРґСѓР»СЊ СЏРґСЂР°:" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install -y conntrack" >&2
    echo "  Fedora/RHEL:   sudo dnf install -y conntrack-tools   # РёР»Рё: yum install conntrack-tools" >&2
    echo "  РњРѕРґСѓР»СЊ:        sudo modprobe nf_conntrack 2>/dev/null; lsmod | grep nf_conntrack" >&2
    echo "  РЎРѕР±С‹С‚РёСЏ conntrack С‡Р°СЃС‚Рѕ С‚СЂРµР±СѓСЋС‚ root: sudo $0 collect" >&2
    exit 1
  }
  echo "[stats-mtproxy] РџРѕСЂС‚ С…РѕСЃС‚Р°: ${proxy_port}. РџРёС€РµРј СЃРµСЃСЃРёРё РІ ${SESSIONS_FILE}" >&2
  if [[ -n "${MTPROXY_COLLECT_EVENTS:-}" ]]; then
    echo "[stats-mtproxy] Р РµР¶РёРј conntrack -E (СЌРєСЃРїРµСЂРёРјРµРЅС‚Р°Р»СЊРЅРѕ)." >&2
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
    echo "РЈСЃС‚Р°РЅРѕРІРёС‚Рµ conntrack (conntrack-tools), Р·Р°С‚РµРј РїРѕРІС‚РѕСЂРёС‚Рµ start." >&2
    exit 1
  }
  if ! conntrack -L >/dev/null 2>&1; then
    echo "conntrack РЅРµРґРѕСЃС‚СѓРїРµРЅ (РЅСѓР¶РЅС‹ РїСЂР°РІР° root / netlink). Р—Р°РїСѓСЃС‚РёС‚Рµ: sudo $0 start" >&2
    exit 1
  fi
  if [[ -f "$PID_FILE" ]]; then
    local old
    old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "РЎР±РѕСЂС‰РёРє СѓР¶Рµ Р·Р°РїСѓС‰РµРЅ (PID $old)."
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
    echo "РЎР±РѕСЂС‰РёРє СЃСЂР°Р·Сѓ Р·Р°РІРµСЂС€РёР»СЃСЏ. РџРѕСЃР»РµРґРЅРёРµ СЃС‚СЂРѕРєРё ${logf}:" >&2
    tail -n 25 "$logf" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "РџРѕРґСЃРєР°Р·РєР°: sudo $0 diagnose" >&2
    exit 1
  fi
  echo "РЎР±РѕСЂС‰РёРє Р·Р°РїСѓС‰РµРЅ, PID ${pid}, Р»РѕРі: $logf (РїРѕСЂС‚ ${proxy_port})"
}

stop_background() {
  [[ -f "$PID_FILE" ]] || {
    echo "PID-С„Р°Р№Р» РЅРµ РЅР°Р№РґРµРЅ."
    exit 0
  }
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "РћСЃС‚Р°РЅРѕРІР»РµРЅ PID $pid"
  else
    echo "РџСЂРѕС†РµСЃСЃ РЅРµ РЅР°Р№РґРµРЅ."
  fi
  rm -f "$PID_FILE"
}

collector_status() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "РЎР±РѕСЂС‰РёРє СЂР°Р±РѕС‚Р°РµС‚ (PID $pid)"
      return 0
    fi
    if [[ -n "$pid" ]]; then
      echo "РЎР±РѕСЂС‰РёРє РЅРµ Р·Р°РїСѓС‰РµРЅ (РІ ${PID_FILE} Р·Р°РїРёСЃР°РЅ PID $pid вЂ” РїСЂРѕС†РµСЃСЃ Р·Р°РІРµСЂС€РёР»СЃСЏ)."
    fi
  else
    echo "РЎР±РѕСЂС‰РёРє РЅРµ Р·Р°РїСѓС‰РµРЅ (РЅРµС‚ ${PID_FILE})."
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
    echo "в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ stats-mtproxy diagnose в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ"
    echo "CONFIG_FILE=${CONFIG_FILE}"
    echo "STATEDIR=${STATEDIR}"
    echo "PORT РёР· РєРѕРЅС„РёРіР° (С…РѕСЃС‚): ${proxy_port}"
    if [[ -f "$SESSIONS_FILE" ]]; then
      echo "sessions.tsv: ${SESSIONS_FILE} ($(wc -c <"$SESSIONS_FILE") Р±Р°Р№С‚)"
    else
      echo "sessions.tsv: С„Р°Р№Р»Р° РµС‰С‘ РЅРµС‚"
    fi
    echo "EUID=${EUID:-} SUDO_UID=${SUDO_UID:-}"
    echo ""
    if command -v conntrack >/dev/null 2>&1; then
      if conntrack -L >/dev/null 2>&1; then
        echo "conntrack -L: OK"
        lines="$(conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | wc -l)"
        echo "Р—Р°РїРёСЃРµР№ conntrack СЃ dport=${proxy_port} (СЃРµР№С‡Р°СЃ): ${lines}"
        echo "РџСЂРёРјРµСЂ (РґРѕ 8 СЃС‚СЂРѕРє СЃ СЌС‚РёРј dport):"
        conntrack -L -p tcp 2>/dev/null | grep "dport=${proxy_port}" | head -8 || echo "  (РїСѓСЃС‚Рѕ вЂ” РЅРµС‚ Р°РєС‚РёРІРЅС‹С… TCP РЅР° СЌС‚РѕС‚ РїРѕСЂС‚ РёР»Рё РґСЂСѓРіРѕРµ РёРјСЏ РїРѕР»РµР№)"
      else
        echo "conntrack -L: РѕС‚РєР°Р· (РЅСѓР¶РµРЅ root). Р—Р°РїСѓСЃРє: sudo $0 diagnose"
      fi
    else
      echo "conntrack: РєРѕРјР°РЅРґР° РЅРµ РЅР°Р№РґРµРЅР° (apt install conntrack)"
    fi
    echo ""
    if command -v ss >/dev/null 2>&1; then
      echo "РџСЂРѕСЃР»СѓС€РёРІР°РЅРёРµ РїРѕСЂС‚Р° ${proxy_port} (ss):"
      ss -tlnp 2>/dev/null | grep -E ":${proxy_port}\\s" || echo "  (РЅРµС‚ LISTEN РЅР° :${proxy_port} РІ РІС‹РІРѕРґРµ ss вЂ” РїСЂРѕРІРµСЂСЊС‚Рµ Docker -p)"
    fi
    echo ""
    if [[ -f "$logf" ]]; then
      echo "РҐРІРѕСЃС‚ ${logf}:"
      tail -n 20 "$logf"
    else
      echo "Р›РѕРі ${logf} РµС‰С‘ РЅРµ СЃРѕР·РґР°РІР°Р»СЃСЏ."
    fi
    echo ""
    echo "РЎР±РѕСЂС‰РёРє РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ РѕРїСЂР°С€РёРІР°РµС‚ conntrack -L (РЅРµ -E); СЃС‚Р°СЂС‹Р№ СЂРµР¶РёРј: MTPROXY_COLLECT_EVENTS=1."
    echo "Р•СЃР»Рё СЃР±РѕСЂС‰РёРє РїР°РґР°РµС‚: sudo $0 start  (РїРѕСЃР»Рµ conntrack-tools)."
    echo "РџСѓСЃС‚РѕР№ РѕС‚С‡С‘С‚: РЅРµС‚ РІС…РѕРґСЏС‰РёС… СЃРµСЃСЃРёР№ РЅР° РїРѕСЂС‚ ${proxy_port} РїРѕСЃР»Рµ start (РёР»Рё С‚РѕР»СЊРєРѕ src 172.16вЂ“31 / 127.* вЂ” РѕС‚С„РёР»СЊС‚СЂРѕРІР°РЅС‹)."
    echo "в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ"
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
    echo "РџРѕРєР° РЅРµС‚ Р·Р°РїРёСЃРµР№ РІ ${SESSIONS_FILE}."
    echo "Р—Р°РїСѓСЃС‚РёС‚Рµ СЃР±РѕСЂС‰РёРє (conntrack-tools), СЃ С‚РµРјРё Р¶Рµ РїСѓС‚СЏРјРё, С‡С‚Рѕ Рё РѕС‚С‡С‘С‚:"
    echo "  ./stats-mtproxy.sh start   РёР»Рё   sudo ./stats-mtproxy.sh start"
    echo "(РїРѕРґ sudo РґР°РЅРЅС‹Рµ РїРёС€СѓС‚СЃСЏ РІ РґРѕРјР°С€РЅРёР№ РєР°С‚Р°Р»РѕРі РїРѕР»СЊР·РѕРІР°С‚РµР»СЏ, РµСЃР»Рё РµСЃС‚СЊ ~/mtproto_config.txt)."
    echo "Р•СЃР»Рё СЂР°РЅРµРµ Р·Р°РїСѓСЃРєР°Р»Рё С‚РѕР»СЊРєРѕ sudo Р±РµР· СЌС‚РѕРіРѕ РїРѕРІРµРґРµРЅРёСЏ вЂ” РѕСЃС‚Р°РЅРѕРІРёС‚Рµ СЃС‚Р°СЂС‹Р№ РїСЂРѕС†РµСЃСЃ Рё Р·Р°РїСѓСЃС‚РёС‚Рµ start Р·Р°РЅРѕРІРѕ."
    echo "Р”РёР°РіРЅРѕСЃС‚РёРєР°: ./stats-mtproxy.sh diagnose   РёР»Рё   sudo ./stats-mtproxy.sh diagnose"
    collector_status || true
    echo ""
    return 0
  fi

  echo ""
  echo "РЎС‚Р°С‚РёСЃС‚РёРєР° РїРѕ IP (РїРѕСЂС‚ РїСЂРѕРєСЃРё РЅР° С…РѕСЃС‚Рµ: ${proxy_port})."
  echo "в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ"

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
    "IP" "РџРµСЂРІРѕРµ СЃРѕРµРґРёРЅРµРЅРёРµ" "РЎРµРіРѕРґРЅСЏ" "7 РґРЅРµР№" "30 РґРЅРµР№" "Р’СЃРµРіРѕ"

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

  echo "в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ"
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
        echo "reset trim [ -y ] вЂ” СѓР±СЂР°С‚СЊ РёР· С„Р°Р№Р»Р° СЃС‚СЂРѕРєРё СЃ В«СЃР»СѓР¶РµР±РЅС‹РјРёВ» IP (СЃРј. README)."
        echo "reset all  [ -y ] вЂ” Р±СЌРєР°Рї sessions.tsv Рё РѕР±РЅСѓР»РµРЅРёРµ."
        return 0
        ;;
      *)
        echo "РќРµРёР·РІРµСЃС‚РЅС‹Р№ Р°СЂРіСѓРјРµРЅС‚ reset: $a" >&2
        echo "РСЃРїРѕР»СЊР·СѓР№С‚Рµ: $0 reset trim|all [ -y ]" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$mode" ]] || {
    echo "РЈРєР°Р¶РёС‚Рµ СЂРµР¶РёРј: $0 reset trim|all [ -y ]" >&2
    exit 1
  }
  if [[ ! -f "$SESSIONS_FILE" ]] || [[ ! -s "$SESSIONS_FILE" ]]; then
    echo "Р¤Р°Р№Р» ${SESSIONS_FILE} РїСѓСЃС‚ РёР»Рё РѕС‚СЃСѓС‚СЃС‚РІСѓРµС‚ вЂ” СЃР±СЂР°СЃС‹РІР°С‚СЊ РЅРµС‡РµРіРѕ."
    return 0
  fi
  if [[ "$yes" != 1 ]]; then
    local prompt
    if [[ "$mode" == trim ]]; then
      prompt="РЈРґР°Р»РёС‚СЊ РёР· ${SESSIONS_FILE} С‚РѕР»СЊРєРѕ СЃС‚СЂРѕРєРё Docker/127 (Р±СЌРєР°Рї .bak.РґР°С‚Р°)? [y/N] "
    else
      prompt="РЎРґРµР»Р°С‚СЊ Р±СЌРєР°Рї Рё РћР‘РќРЈР›РРўР¬ РІРµСЃСЊ ${SESSIONS_FILE}? [y/N] "
    fi
    read -r -p "$prompt" _c || true
    [[ "${_c:-}" == y || "${_c:-}" == Y ]] || {
      echo "РћС‚РјРµРЅРµРЅРѕ."
      exit 0
    }
  fi
  local bak
  bak="${SESSIONS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$SESSIONS_FILE" "$bak" || {
    echo "РќРµ СѓРґР°Р»РѕСЃСЊ СЃРѕР·РґР°С‚СЊ Р±СЌРєР°Рї ${bak}" >&2
    exit 1
  }
  echo "Р‘СЌРєР°Рї: ${bak}"
  if [[ "$mode" == trim ]]; then
    awk 'NF >= 4 {
      ip = $3
      if (ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      if (ip ~ /^127\./) next
      if (ip ~ /^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\./) next
      print
    }' "$bak" >"${SESSIONS_FILE}.tmp" && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Р“РѕС‚РѕРІРѕ: СѓРґР°Р»РµРЅС‹ СЃС‚СЂРѕРєРё СЃ РѕС‚С„РёР»СЊС‚СЂРѕРІР°РЅРЅС‹РјРё IP."
  else
    : >"$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    echo "Р“РѕС‚РѕРІРѕ: С„Р°Р№Р» РѕР±РЅСѓР»С‘РЅ."
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

