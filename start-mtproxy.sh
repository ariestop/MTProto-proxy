#!/usr/bin/env bash
# Образ telegrammessenger/proxy на Docker Hub давно не обновлялся; при необходимости
# соберите свой из официального исходника или укажите другой тег:
#   DOCKER_IMAGE=your/mtproxy:latest ./start-mtproxy.sh
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTAINER_NAME="mtproto-proxy"
DOCKER_IMAGE="${DOCKER_IMAGE:-telegrammessenger/proxy:latest}"
CONFIG_FILE="${HOME}/mtproto_config.txt"
DATA_VOLUME="mtproxy-data"
DEFAULT_DOMAIN="ya.ru"

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
SERVER_SECRET=${SERVER_SECRET}
CLIENT_SECRET=${CLIENT_SECRET}
DOMAIN=${FAKE_DOMAIN}
TAG=${PROXY_TAG}
LINK=tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${CLIENT_SECRET}
IMAGE=${DOCKER_IMAGE}
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# Значения без цвета на отдельных строках — удобно выделить мышью / двойной клик
emit_copy_block() {
  local server_ip="$1" port="$2" server_secret="$3" client_secret="$4" domain="$5"
  local tag="${6:-}"
  local link="tg://proxy?server=${server_ip}&port=${port}&secret=${client_secret}"

  echo
  echo "═══════════════════════════════════════════════════════════"
  echo " Скопируйте значения (ниже — только текст, без цветов)"
  echo "═══════════════════════════════════════════════════════════"
  echo "Адрес для @MTProxybot (одна строка):"
  printf '%s\n\n' "${server_ip}:${port}"
  echo "Серверный secret для бота (32 hex, не ee...):"
  printf '%s\n\n' "${server_secret}"
  echo "Клиентский Fake TLS secret (для Telegram):"
  printf '%s\n\n' "${client_secret}"
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
  local SERVER PORT_OUT SERVER_SECRET_OUT CLIENT_SECRET_OUT DOMAIN_OUT TAG_OUT LINK_OUT
  SERVER=$(cfg_get SERVER)
  PORT_OUT=$(cfg_get PORT)
  SERVER_SECRET_OUT=$(cfg_get SERVER_SECRET)
  CLIENT_SECRET_OUT=$(cfg_get CLIENT_SECRET)
  DOMAIN_OUT=$(cfg_get DOMAIN)
  TAG_OUT=$(cfg_get TAG)
  LINK_OUT=$(cfg_get LINK)
  [[ -n "$SERVER" && -n "$PORT_OUT" && -n "$CLIENT_SECRET_OUT" ]] || fail "В конфиге не хватает полей (SERVER, PORT, CLIENT_SECRET)."
  if [[ -z "$LINK_OUT" ]]; then
    LINK_OUT="tg://proxy?server=${SERVER}&port=${PORT_OUT}&secret=${CLIENT_SECRET_OUT}"
  fi

  echo
  log "📊 Данные для подключения (цветной обзор):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🌐 Сервер: ${BLUE}${SERVER}${NC}"
  echo -e "🔌 Порт: ${BLUE}${PORT_OUT}${NC}"
  echo -e "🔑 Серверный secret: ${YELLOW}${SERVER_SECRET_OUT}${NC}"
  echo -e "🔐 Клиентский secret: ${YELLOW}${CLIENT_SECRET_OUT}${NC}"
  echo -e "🌐 Fake TLS домен: ${BLUE}${DOMAIN_OUT}${NC}"
  [[ -n "$TAG_OUT" ]] && echo -e "🏷️ TAG: ${YELLOW}${TAG_OUT}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🔗 Ссылка: ${GREEN}${LINK_OUT}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  emit_copy_block "$SERVER" "$PORT_OUT" "$SERVER_SECRET_OUT" "$CLIENT_SECRET_OUT" "$DOMAIN_OUT" "$TAG_OUT"
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
  echo
}

show_logs() {
  ensure_dependencies
  echo
  echo "📋 Последние логи контейнера:"
  sudo docker logs --tail 30 "$CONTAINER_NAME" 2>/dev/null || warn "Логи недоступны (контейнер отсутствует?)"
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

  DOMAIN_HEX="$(printf '%s' "$FAKE_DOMAIN" | xxd -ps -c 999 | tr -d '\n')"
  [[ -n "$DOMAIN_HEX" ]] || fail "Не удалось закодировать домен."

  log -n "🔑 Генерация secret... "
  SERVER_SECRET="$(openssl rand -hex 16 | tr '[:upper:]' '[:lower:]')"
  CLIENT_SECRET="ee${SERVER_SECRET}${DOMAIN_HEX}"
  log "${GREEN}готово${NC}"
  echo -e "   Серверный secret: ${YELLOW}${SERVER_SECRET}${NC}"
  echo -e "   Клиентский secret: ${YELLOW}${CLIENT_SECRET}${NC}"
  emit_copy_block "$SERVER_IP" "$PORT" "$SERVER_SECRET" "$CLIENT_SECRET" "$FAKE_DOMAIN" ""

  echo
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "${YELLOW}Регистрация в @MTProxybot (secret — только серверный 32 hex, не ee...)${NC}"
  echo -e "1. ${BLUE}/newproxy${NC}"
  echo -e "2. Адрес: ${BLUE}${SERVER_IP}:${PORT}${NC}"
  echo -e "3. Secret: ${BLUE}${SERVER_SECRET}${NC}"
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
    -e "SECRET=${SERVER_SECRET}"
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
  echo -e "🔑 Серверный secret: ${YELLOW}${SERVER_SECRET}${NC}"
  echo -e "🔐 Клиентский secret: ${YELLOW}${CLIENT_SECRET}${NC}"
  echo -e "🌐 Fake TLS домен: ${BLUE}${FAKE_DOMAIN}${NC}"
  [[ -n "${PROXY_TAG}" ]] && echo -e "🏷️ TAG: ${YELLOW}${PROXY_TAG}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🔗 Ссылка: ${GREEN}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${CLIENT_SECRET}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  emit_copy_block "$SERVER_IP" "$PORT" "$SERVER_SECRET" "$CLIENT_SECRET" "$FAKE_DOMAIN" "${PROXY_TAG:-}"
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
