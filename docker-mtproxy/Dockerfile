# Сборка официального MTProxy из https://github.com/TelegramMessenger/MTProxy
# Образ можно переносить: docker save / docker load

FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG MTPROXY_REPO=https://github.com/TelegramMessenger/MTProxy.git
ARG MTPROXY_REF=master

RUN git clone --depth 1 --branch "${MTPROXY_REF}" "${MTPROXY_REPO}" . \
    && make -j"$(nproc)" \
    && strip objs/bin/mtproto-proxy

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    zlib1g \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/mtproto-proxy

WORKDIR /var/lib/mtproxy
EXPOSE 443

ENV SECRET=""
ENV TAG=""

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
