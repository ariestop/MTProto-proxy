#!/usr/bin/env bash
# Собирает Docker-образ MTProxy из официального исходника:
# https://github.com/TelegramMessenger/MTProxy
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CTX="${SCRIPT_DIR}/docker-mtproxy"
IMAGE="${MTPROXY_IMAGE:-local/mtproxy:latest}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  echo "Использование: $0 [-t образ:тег] [--no-cache]"
  echo "  -t   Имя и тег образа (по умолчанию: local/mtproxy:latest)"
  echo "       То же можно задать переменной MTPROXY_IMAGE"
  echo "  --no-cache   Полная пересборка без кэша Docker"
  echo ""
  echo "После сборки для start-mtproxy.sh: export DOCKER_IMAGE=$IMAGE"
}

NO_CACHE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      IMAGE="$2"
      shift 2
      ;;
    --no-cache)
      NO_CACHE=(--no-cache)
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Ошибка: нужен Docker (команда docker в PATH)." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Ошибка: Docker не запущен или нет прав (проверьте группу docker или sudo)." >&2
  exit 1
fi

if [[ ! -f "${DOCKER_CTX}/Dockerfile" || ! -f "${DOCKER_CTX}/entrypoint.sh" ]]; then
  echo "Ошибка: не найдены ${DOCKER_CTX}/Dockerfile или entrypoint.sh" >&2
  exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Сборка образа MTProxy из GitHub (TelegramMessenger/MTProxy)${NC}"
echo -e "Контекст: ${YELLOW}${DOCKER_CTX}${NC}"
echo -e "Тег образа: ${YELLOW}${IMAGE}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

docker build "${NO_CACHE[@]}" -t "$IMAGE" "$DOCKER_CTX"

echo ""
echo -e "${GREEN}Образ собран: ${IMAGE}${NC}"
echo ""
echo "Перенос на другой сервер (пример):"
echo "  docker save \"$IMAGE\" | gzip > mtproxy-image.tar.gz"
echo "  scp mtproxy-image.tar.gz user@другой-сервер:"
echo "На целевом сервере:"
echo "  gunzip -c mtproxy-image.tar.gz | docker load"
echo ""

read -r -p "Сохранить образ в tar.gz в каталог проекта? [y/N] " SAVE_ANS
if [[ "${SAVE_ANS:-}" =~ ^[yY]$ ]]; then
  OUT="${SCRIPT_DIR}/mtproxy-image-$(date +%Y%m%d-%H%M).tar.gz"
  echo "Сохранение в ${OUT} ..."
  docker save "$IMAGE" | gzip >"$OUT"
  echo -e "${GREEN}Готово: ${OUT}${NC}"
  echo ""
fi

read -r -p "Запустить start-mtproxy.sh для настройки прокси? [y/N] " RUN_CFG
if [[ "${RUN_CFG:-}" =~ ^[yY]$ ]]; then
  if [[ ! -x "${SCRIPT_DIR}/start-mtproxy.sh" ]]; then
    chmod +x "${SCRIPT_DIR}/start-mtproxy.sh" 2>/dev/null || true
  fi
  if [[ ! -f "${SCRIPT_DIR}/start-mtproxy.sh" ]]; then
    echo "Файл start-mtproxy.sh не найден в ${SCRIPT_DIR}" >&2
    exit 1
  fi
  export DOCKER_IMAGE="$IMAGE"
  echo -e "${GREEN}Запуск с DOCKER_IMAGE=${IMAGE}${NC}"
  exec "${SCRIPT_DIR}/start-mtproxy.sh"
fi

echo "Для настройки позже выполните:"
echo -e "  ${YELLOW}export DOCKER_IMAGE=${IMAGE}${NC}"
echo "  ./start-mtproxy.sh"
