#!/usr/bin/env bash
set -euo pipefail

: "${SECRET:?Переменная SECRET обязательна (32 hex для сервера)}"

WORKDIR=/var/lib/mtproxy
mkdir -p "$WORKDIR"
cd "$WORKDIR"

curl -fsSL --max-time 60 https://core.telegram.org/getProxySecret -o proxy-secret
curl -fsSL --max-time 60 https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# Как в README MTProxy: локальный порт статистики, -H — порт для клиентов (в контейнере 443)
ARGS=( -p 8888 -H 443 -S "${SECRET}" --aes-pwd proxy-secret proxy-multi.conf -M 1 )
if [[ -n "${TAG:-}" ]]; then
  ARGS+=( -P "${TAG}" )
fi

exec /usr/local/bin/mtproto-proxy "${ARGS[@]}"
