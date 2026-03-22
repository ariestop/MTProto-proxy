#!/usr/bin/env bash
set -euo pipefail

: "${SECRET:?Переменная SECRET обязательна (32 hex для сервера)}"

WORKDIR=/var/lib/mtproxy
mkdir -p "$WORKDIR"
cd "$WORKDIR"

curl -fsSL --max-time 60 https://core.telegram.org/getProxySecret -o proxy-secret
curl -fsSL --max-time 60 https://core.telegram.org/getProxyConfig -o proxy-multi.conf

chown mtproxy:mtproxy proxy-secret proxy-multi.conf

# NAT: Docker даёт контейнеру внутренний IP; прокси должен знать внешний.
INTERNAL_IP="$(hostname -I | awk '{print $1}')"
if [[ -z "${EXTERNAL_IP:-}" ]]; then
  EXTERNAL_IP="$(curl -fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null \
              || curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
              || true)"
fi

ARGS=( -p 8888 -H 443 -S "${SECRET}" --aes-pwd proxy-secret proxy-multi.conf
       -M "${WORKERS:-2}" )

if [[ -n "${INTERNAL_IP:-}" && -n "${EXTERNAL_IP:-}" ]]; then
  ARGS+=( --nat-info "${INTERNAL_IP}:${EXTERNAL_IP}" )
fi

if [[ -n "${TAG:-}" ]]; then
  ARGS+=( -P "${TAG}" )
fi

exec /usr/local/bin/mtproto-proxy "${ARGS[@]}"
