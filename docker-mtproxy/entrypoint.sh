#!/usr/bin/env bash
set -euo pipefail

: "${SECRET:?Переменная SECRET обязательна (32 hex для сервера)}"

WORKDIR=/var/lib/mtproxy
mkdir -p "$WORKDIR"
cd "$WORKDIR"

curl -fsSL --max-time 60 https://core.telegram.org/getProxySecret -o proxy-secret
curl -fsSL --max-time 60 https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# Бинарник и воркеры переключаются на пользователя mtproxy (создаётся в Dockerfile)
chown mtproxy:mtproxy proxy-secret proxy-multi.conf

# Как в README MTProxy: -p статистика, -H порт клиентов (443 в контейнере)
ARGS=( -p 8888 -H 443 -S "${SECRET}" --aes-pwd proxy-secret proxy-multi.conf -M 1 )
if [[ -n "${TAG:-}" ]]; then
  ARGS+=( -P "${TAG}" )
fi

exec /usr/local/bin/mtproto-proxy "${ARGS[@]}"
