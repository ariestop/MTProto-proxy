#!/usr/bin/env bash
# Образ: пункт меню 8 или ~/.mtproxy_docker_image; иначе DOCKER_IMAGE из окружения.
# Переопределение разово: DOCKER_IMAGE=local/mtproxy:latest ./start-mtproxy.sh (см. ./install-mtproxy.sh)
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd)"
STATS_SCRIPT="${SCRIPT_DIR}/stats-mtproxy.sh"

CONTAINER_NAME="mtproto-proxy"
CONFIG_FILE="${HOME}/mtproto_config.txt"
PREF_IMAGE_FILE="${HOME}/.mtproxy_docker_image"
DATA_VOLUME="mtproxy-data"
DEFAULT_DOMAIN="ya.ru"

# Приоритет: переменная окружения DOCKER_IMAGE → ~/.mtproxy_docker_image → IMAGE= в конфиге → Hub
if [[ -z "${DOCKER_IMAGE:-}" ]]; then
  _img_saved=""
  if [[ -f "$PREF_IMAGE_FILE" ]]; then
    _img_saved="$(head -n1 "$PREF_IMAGE_FILE" | tr -d '\r\n')"
  elif [[ -f "$CONFIG_FILE" ]]; then
    _img_saved="$(grep -m1 '^IMAGE=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)"
  fi
  DOCKER_IMAGE="${_img_saved:-telegrammessenger/proxy:latest}"
  unset _img_saved
fi

log() {
  if [[ "${1:-}" == "-n" ]]; then
    shift
    echo -ne "$1"
  else
    echo -e "$1"
  fi
}

ok() {
  echo -e "${GREEN}✅ $1${NC}"
}

warn() {
  echo -e "${YELLOW}⚠️ $1${NC}"
}

fail() {
  echo -e "${RED}❌ $1${NC}" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена команда: $1"
}

require_port_checker() {
  if command -v ss >/dev/null 2>&1; then
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  fail "Нужна команда ss или lsof для проверки портов."
}

ensure_dependencies() {
  require_cmd docker
  require_cmd curl
  require_cmd openssl
  require_cmd xxd
  require_port_checker
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

choose_default_port() {
  local candidate
  for candidate in 443 8443 8444 8445; do
    if ! port_in_use "$candidate"; then
      echo "$candidate"
      return
    fi
  done
  echo "443"
}

get_public_ip() {
  curl -fsS --max-time 10 --retry 2 "https://ifconfig.me/ip" 2>/dev/null || true
}

is_valid_server() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  [[ ! "$s" =~ [[:space:]] ]] || return 1
  if [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    local -a oct
    read -r -a oct <<<"$s"
    local o
    for o in "${oct[@]}"; do
      (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
  fi
  [[ ${#s} -le 253 ]] || return 1
  [[ "$s" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

is_valid_fake_domain() {
  local d="$1"
  [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
  [[ ! "$d" =~ [[:space:]] ]] || return 1
  [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

stop_container() {
  sudo docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

remove_container() {
  sudo docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  sudo docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

container_exists() {
  sudo docker ps -a --format '{{.Names}}' | grep -qxF "$CONTAINER_NAME"
}

container_running() {
  sudo docker ps --format '{{.Names}}' | grep -qxF "$CONTAINER_NAME"
}

get_container_host_port() {
  sudo docker port "$CONTAINER_NAME" 443/tcp 2>/dev/null | awk -F: 'NF { print $NF; exit }'
}

save_config() {
  umask 077
  cat >"$CONFIG_FILE" <<EOF
SERVER=${SERVER_IP}
PORT=${PORT}
SECRET=${PROXY_SECRET}
DOMAIN=${FAKE_DOMAIN}
TAG=${PROXY_TAG}
LINK=tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${PROXY_SECRET}
IMAGE=${DOCKER_IMAGE}
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  persist_docker_image_pref
}

persist_docker_image_pref() {
  umask 077
  printf '%s\n' "$DOCKER_IMAGE" >"$PREF_IMAGE_FILE"
  chmod 600 "$PREF_IMAGE_FILE" 2>/dev/null || true
}

update_config_image_line() {
  local new_img="$1"
  [[ -f "$CONFIG_FILE" ]] || return 0
  local tmp
  tmp=$(mktemp) || return 0
  if grep -q '^IMAGE=' "$CONFIG_FILE" 2>/dev/null; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^IMAGE= ]]; then
        echo "IMAGE=${new_img}"
      else
        printf '%s\n' "$line"
      fi
    done <"$CONFIG_FILE" >"$tmp"
    mv "$tmp" "$CONFIG_FILE"
  else
    rm -f "$tmp"
    echo "IMAGE=${new_img}" >>"$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

choose_docker_image() {
  ensure_dependencies
  echo
  log "🐳 Образ Docker для следующей установки прокси"
  echo -e "Сейчас выбрано: ${BLUE}${DOCKER_IMAGE}${NC}"
  echo
  echo "  1) Docker Hub — telegrammessenger/proxy:latest"
  echo "  2) Локальная сборка — local/mtproxy:latest (сначала: ./install-mtproxy.sh)"
  echo "  0) Назад без изменений"
  echo
  read -r -p "Выбор: " img_choice
  case "$img_choice" in
    1)
      DOCKER_IMAGE="telegrammessenger/proxy:latest"
      ;;
    2)
      DOCKER_IMAGE="local/mtproxy:latest"
      ;;
    0 | "")
      echo
      return 0
      ;;
    *)
      warn "Неверный выбор"
      echo
      return 0
      ;;
  esac
  persist_docker_image_pref
  update_config_image_line "$DOCKER_IMAGE"
  ok "Сохранено: ${DOCKER_IMAGE}"
  echo -e "Файл настроек: ${BLUE}${PREF_IMAGE_FILE}${NC}"
  echo
}

# Значения без цвета на отдельных строках — удобно выделить мышью / двойной клик
emit_copy_block() {
  local server_ip="$1" port="$2" secret="$3" domain="$4"
  local tag="${5:-}"
  local link="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"

  echo
  echo "═══════════════════════════════════════════════════════════"
  echo " Скопируйте значения (ниже — только текст, без цветов)"
  echo "═══════════════════════════════════════════════════════════"
  echo "Адрес для @MTProxybot (одна строка):"
  printf '%s\n\n' "${server_ip}:${port}"
  echo "Secret (одна строка для бота, Docker и Telegram):"
  printf '%s\n\n' "${secret}"
  echo "Домен Fake TLS:"
  printf '%s\n\n' "${domain}"
  if [[ -n "${tag}" ]]; then
    echo "TAG:"
    printf '%s\n\n' "${tag}"
  fi
  echo "Ссылка tg://proxy (одна строка):"
  printf '%s\n' "${link}"
  echo "═══════════════════════════════════════════════════════════"
  echo
}

# Не использовать source для конфига — безопасное чтение KEY=value
cfg_get() {
  local key="$1"
  grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

show_existing_container_info() {
  local port status
  status="остановлен"
  if container_running; then
    status="запущен"
  fi
  port="$(get_container_host_port || true)"

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 Найден существующий контейнер: ${CONTAINER_NAME}"
  echo -e "📌 Статус: ${BLUE}${status}${NC}"
  if [[ -n "${port:-}" ]]; then
    echo -e "🔌 Текущий порт (хост): ${BLUE}${port}${NC}"
  else
    echo -e "🔌 Текущий порт: ${YELLOW}не удалось определить${NC}"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "📄 Сохранённый конфиг: ${BLUE}${CONFIG_FILE}${NC}"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
}

ask_for_free_port() {
  local input_port
  while true; do
    read -r -p "Введите свободный порт хоста: " input_port
    [[ "$input_port" =~ ^[0-9]+$ ]] || {
      warn "Порт должен быть числом"
      continue
    }
    [[ "$input_port" -ge 1 && "$input_port" -le 65535 ]] || {
      warn "Порт должен быть в диапазоне 1–65535"
      continue
    }
    if port_in_use "$input_port"; then
      warn "Порт $input_port уже занят"
      continue
    fi
    PORT="$input_port"
    return
  done
}

show_connection_data() {
  [[ -f "$CONFIG_FILE" ]] || fail "Файл конфигурации не найден: $CONFIG_FILE"
  local SERVER PORT_OUT SECRET_OUT DOMAIN_OUT TAG_OUT LINK_OUT
  SERVER=$(cfg_get SERVER)
  PORT_OUT=$(cfg_get PORT)
  SECRET_OUT=$(cfg_get SECRET)
  [[ -n "$SECRET_OUT" ]] || SECRET_OUT=$(cfg_get CLIENT_SECRET)
  DOMAIN_OUT=$(cfg_get DOMAIN)
  TAG_OUT=$(cfg_get TAG)
  LINK_OUT=$(cfg_get LINK)
  [[ -n "$SERVER" && -n "$PORT_OUT" && -n "$SECRET_OUT" ]] || fail "В конфиге не хватает полей (SERVER, PORT, SECRET или CLIENT_SECRET)."
  if [[ -z "$LINK_OUT" ]]; then
    LINK_OUT="tg://proxy?server=${SERVER}&port=${PORT_OUT}&secret=${SECRET_OUT}"
  fi

  echo
  log "📊 Данные для подключения (цветной обзор):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🌐 Сервер: ${BLUE}${SERVER}${NC}"
  echo -e "🔌 Порт: ${BLUE}${PORT_OUT}${NC}"
  echo -e "🔑 Secret: ${YELLOW}${SECRET_OUT}${NC}"
  echo -e "🌐 Fake TLS домен: ${BLUE}${DOMAIN_OUT}${NC}"
  [[ -n "$TAG_OUT" ]] && echo -e "🏷️ TAG: ${YELLOW}${TAG_OUT}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🔗 Ссылка: ${GREEN}${LINK_OUT}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  emit_copy_block "$SERVER" "$PORT_OUT" "$SECRET_OUT" "$DOMAIN_OUT" "$TAG_OUT"
}

show_status() {
  ensure_dependencies
  echo
  echo "📦 Статус контейнера:"
  if container_running; then
    ok "Контейнер запущен"
  elif container_exists; then
    warn "Контейнер есть, но остановлен"
  else
    warn "Контейнер не найден"
  fi
  echo
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "📄 Конфигурация: ${BLUE}${CONFIG_FILE}${NC} (секреты — в пункте 5, с блоком для копирования)"
  else
    warn "Файл конфигурации ещё не создан"
  fi
  echo -e "🐳 Образ Docker: ${BLUE}${DOCKER_IMAGE}${NC}"
  echo
}

show_logs() {
  ensure_dependencies
  echo
  echo "📋 Последние логи: ${CONTAINER_NAME}"
  if ! container_exists; then
    warn "Контейнер не найден (см. docker ps -a)."
    echo
    return 0
  fi
  local _lf
  _lf=$(mktemp) || {
    warn "Не удалось создать временный файл; вывод без проверки на пустоту."
    sudo docker logs -t --tail 100 "$CONTAINER_NAME" 2>&1 || warn "docker logs завершился с ошибкой."
    echo
    return 0
  }
  if sudo docker logs -t --tail 100 "$CONTAINER_NAME" >"$_lf" 2>&1; then
    if [[ ! -s "$_lf" ]]; then
      echo "(В журнале Docker нет строк — редко для mtproxy; проверьте драйвер логов.)"
      echo "Вручную: sudo docker logs -t --tail 200 ${CONTAINER_NAME}"
      echo "Поток:     sudo docker logs -f ${CONTAINER_NAME}"
    else
      cat "$_lf"
    fi
  else
    warn "Ошибка docker logs:"
    cat "$_lf"
  fi
  rm -f "$_lf"
  echo
}

install_proxy() {
  ensure_dependencies

  echo
  log "🚀 Установка MTProto прокси с Fake TLS"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if container_running; then
    show_existing_container_info
    echo "Контейнер уже запущен."
    echo "1) Остановить и удалить, затем настроить заново"
    echo "2) Отмена"
    read -r -p "Выбор: " old_choice
    case "$old_choice" in
      1)
        log -n "🛑 Остановка контейнера... "
        stop_container
        log "${GREEN}готово${NC}"
        log -n "🗑️ Удаление контейнера... "
        sudo docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        log "${GREEN}готово${NC}"
        ;;
      *)
        warn "Установка отменена"
        echo
        return 0
        ;;
    esac
  elif container_exists; then
    show_existing_container_info
    echo "Контейнер остановлен."
    echo "1) Удалить и настроить заново"
    echo "2) Отмена"
    read -r -p "Выбор: " old_choice
    case "$old_choice" in
      1)
        log -n "🗑️ Удаление контейнера... "
        sudo docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        log "${GREEN}готово${NC}"
        ;;
      *)
        warn "Установка отменена"
        echo
        return 0
        ;;
    esac
  fi

  local detected_ip input_ip input_domain
  detected_ip="$(get_public_ip)"
  read -r -p "Внешний IP или hostname сервера${detected_ip:+ (Enter — ${detected_ip})}: " input_ip
  SERVER_IP="${input_ip:-$detected_ip}"
  [[ -n "$SERVER_IP" ]] || fail "Укажите адрес вручную (автоопределение не сработало)."
  is_valid_server "$SERVER_IP" || fail "Некорректный адрес (IPv4 или hostname)."
  log "📌 Сервер: ${BLUE}${SERVER_IP}${NC}"

  local default_port
  default_port="$(choose_default_port)"
  read -r -p "Порт хоста (Enter — ${default_port}): " input_port
  PORT="${input_port:-$default_port}"
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "Некорректный порт: ${PORT}"
  [[ "$PORT" -ge 1 && "$PORT" -le 65535 ]] || fail "Порт вне диапазона 1–65535: ${PORT}"

  if port_in_use "$PORT"; then
    warn "Порт ${PORT} занят. Укажите свободный порт."
    ask_for_free_port
  fi
  log "📌 Порт: ${BLUE}${PORT}${NC}"

  read -r -p "Домен Fake TLS (Enter — ${DEFAULT_DOMAIN}): " input_domain
  FAKE_DOMAIN="${input_domain:-$DEFAULT_DOMAIN}"
  is_valid_fake_domain "$FAKE_DOMAIN" || fail "Некорректное имя домена."
  log "📌 Домен: ${BLUE}${FAKE_DOMAIN}${NC}"

  DOMAIN_HEX="$(printf '%s' "$FAKE_DOMAIN" | xxd -ps -c 999 | tr -d '\n' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$DOMAIN_HEX" ]] || fail "Не удалось закодировать домен."
  local DOMAIN_LEN NEEDED FULLRAND RANDOM_HEX
  DOMAIN_LEN=${#DOMAIN_HEX}
  if (( DOMAIN_LEN > 30 )); then
    fail "Домен в hex слишком длинный (${DOMAIN_LEN} символов, максимум 30). Укоротите домен Fake TLS."
  fi
  NEEDED=$((30 - DOMAIN_LEN))

  log -n "🔑 Генерация Fake TLS secret... "
  FULLRAND="$(openssl rand -hex 16 | tr '[:upper:]' '[:lower:]')"
  RANDOM_HEX="${FULLRAND:0:NEEDED}"
  PROXY_SECRET="ee${DOMAIN_HEX}${RANDOM_HEX}"
  log "${GREEN}готово${NC}"
  echo -e "   Secret: ${YELLOW}${PROXY_SECRET}${NC}"
  emit_copy_block "$SERVER_IP" "$PORT" "$PROXY_SECRET" "$FAKE_DOMAIN" ""

  echo
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "${YELLOW}Регистрация в @MTProxybot (тот же secret, что в Docker и в ссылке)${NC}"
  echo -e "1. ${BLUE}/newproxy${NC}"
  echo -e "2. Адрес: ${BLUE}${SERVER_IP}:${PORT}${NC}"
  echo -e "3. Secret: ${BLUE}${PROXY_SECRET}${NC}"
  echo "4. При необходимости скопируйте TAG"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  read -r -p "TAG от бота (Enter — без TAG): " PROXY_TAG
  if [[ -n "${PROXY_TAG}" ]] && ! [[ "${PROXY_TAG}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    fail "TAG: ровно 32 hex-символа."
  fi

  log -n "📦 Запуск контейнера (${DOCKER_IMAGE})... "
  local -a docker_args=(
    run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    -p "${PORT}:443"
    -v "${DATA_VOLUME}:/data"
    -e "SECRET=${PROXY_SECRET}"
    -e "EXTERNAL_IP=${SERVER_IP}"
  )
  [[ -n "${PROXY_TAG}" ]] && docker_args+=(-e "TAG=${PROXY_TAG}")
  docker_args+=("$DOCKER_IMAGE")

  if ! sudo docker "${docker_args[@]}" >/dev/null 2>&1; then
    echo
    fail "Не удалось запустить контейнер."
  fi
  log "${GREEN}готово${NC}"

  sleep 3
  if ! sudo docker ps --format '{{.Names}}' | grep -qxF "$CONTAINER_NAME"; then
    echo
    warn "Контейнер не в списке запущенных"
    sudo docker logs "$CONTAINER_NAME" 2>/dev/null || true
    fail "Запуск не подтверждён. См. логи выше."
  fi

  save_config
  ok "Прокси установлен"
  echo
  log "📊 Итог (цветной обзор):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🌐 Сервер: ${BLUE}${SERVER_IP}${NC}"
  echo -e "🔌 Порт: ${BLUE}${PORT}${NC}"
  echo -e "🔑 Secret: ${YELLOW}${PROXY_SECRET}${NC}"
  echo -e "🌐 Fake TLS домен: ${BLUE}${FAKE_DOMAIN}${NC}"
  [[ -n "${PROXY_TAG}" ]] && echo -e "🏷️ TAG: ${YELLOW}${PROXY_TAG}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🔗 Ссылка: ${GREEN}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${PROXY_SECRET}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  emit_copy_block "$SERVER_IP" "$PORT" "$PROXY_SECRET" "$FAKE_DOMAIN" "${PROXY_TAG:-}"
  echo "✅ Конфигурация: ${CONFIG_FILE} (права 600)"
  show_logs
}

restart_proxy() {
  ensure_dependencies
  echo
  log -n "🔄 Перезапуск... "
  if sudo docker ps -a --format '{{.Names}}' | grep -qxF "$CONTAINER_NAME"; then
    sudo docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || fail "Не удалось перезапустить"
    log "${GREEN}готово${NC}"
    ok "Контейнер перезапущен"
  else
    fail "Контейнер ${CONTAINER_NAME} не найден"
  fi
  echo
}

stop_proxy() {
  ensure_dependencies
  echo
  log -n "🛑 Остановка... "
  if sudo docker ps -a --format '{{.Names}}' | grep -qxF "$CONTAINER_NAME"; then
    stop_container
    log "${GREEN}готово${NC}"
    ok "Контейнер остановлен"
  else
    fail "Контейнер ${CONTAINER_NAME} не найден"
  fi
  echo
}

delete_proxy() {
  ensure_dependencies
  echo
  read -r -p "Удалить контейнер ${CONTAINER_NAME}? [y/N]: " confirm
  case "$confirm" in
    y | Y)
      log -n "🗑️ Удаление контейнера... "
      remove_container
      log "${GREEN}готово${NC}"
      read -r -p "Удалить ${CONFIG_FILE}? [y/N]: " del_cfg
      case "$del_cfg" in
        y | Y)
          rm -f "$CONFIG_FILE"
          ok "Конфиг удалён"
          ;;
      esac
      ok "Контейнер удалён"
      ;;
    *)
      warn "Отменено"
      ;;
  esac
  echo
}

stats_submenu() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Статистика абонентов (IP, время сессий)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "1) Показать отчёт"
  echo "2) Запустить сборщик в фоне (Linux, conntrack)"
  echo "3) Остановить сборщик"
  echo "4) Статус сборщика"
  echo "0) Назад в главное меню"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -r -p "Выбор: " sub
  case "$sub" in
    1)
      if [[ -f "$STATS_SCRIPT" ]]; then
        bash "$STATS_SCRIPT" report
      else
        warn "Не найден ${STATS_SCRIPT}"
      fi
      ;;
    2)
      if [[ -f "$STATS_SCRIPT" ]]; then
        if [[ "$(uname -s 2>/dev/null)" != Linux ]]; then
          warn "Сборщик рассчитан на Linux (conntrack / nf_conntrack)."
        fi
        bash "$STATS_SCRIPT" start || true
      else
        warn "Не найден ${STATS_SCRIPT}"
      fi
      ;;
    3)
      [[ -f "$STATS_SCRIPT" ]] && bash "$STATS_SCRIPT" stop || warn "Не найден ${STATS_SCRIPT}"
      ;;
    4)
      [[ -f "$STATS_SCRIPT" ]] && bash "$STATS_SCRIPT" status || warn "Не найден ${STATS_SCRIPT}"
      ;;
    0 | "") ;;
    *) warn "Неверный пункт" ;;
  esac
  echo
}

show_menu() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " MTProto Proxy Manager"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "1) Установить / переустановить"
  echo "2) Перезапустить контейнер"
  echo "3) Остановить контейнер"
  echo "4) Удалить контейнер"
  echo "5) Данные для подключения"
  echo "6) Статус"
  echo "7) Логи"
  echo "8) Образ Docker (Hub / локальная сборка)"
  echo "9) Статистика абонентов"
  echo "0) Выход"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
  while true; do
    show_menu
    read -r -p "Выбор: " choice
    case "$choice" in
      1) install_proxy ;;
      2) restart_proxy ;;
      3) stop_proxy ;;
      4) delete_proxy ;;
      5) show_connection_data ;;
      6) show_status ;;
      7) show_logs ;;
      8) choose_docker_image ;;
      9) stats_submenu ;;
      0)
        echo "Выход."
        exit 0
        ;;
      *)
        warn "Неверный пункт"
        echo
        ;;
    esac
  done
}

main
