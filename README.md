# MTProxy — запуск в Docker (Fake TLS)

Интерактивный Bash‑скрипт поднимает [MTProxy](https://github.com/TelegramMessenger/MTProxy) в Docker в режиме **Fake TLS**: генерирует секрет, подсказывает шаги для [@MTProxybot](https://t.me/MTProxybot), запускает контейнер и сохраняет параметры в `~/mtproto_config.txt`. После запуска доступно меню (перезапуск, остановка, удаление, данные подключения, статус, логи, статистика).

## Требования

- **ОС**: Linux (рекомендуется для сервера) или macOS.
- **Docker**: по умолчанию используются команды `sudo docker`.
- **Утилиты** в `PATH`: `bash`, `curl`, `xxd`, `openssl`, `grep`. Для проверки портов — `ss` или `lsof`.

## Быстрый старт

```bash
chmod +x start-mtproxy.sh
./start-mtproxy.sh
```

Скрипт спросит:
- внешний IP/hostname сервера (для ссылки `tg://proxy`);
- порт хоста (по умолчанию первый свободный из `443/8443/8444/8445`);
- домен Fake TLS (по умолчанию `ya.ru`);
- (опционально) TAG от @MTProxybot.

## Сборка своего образа (опционально)

По умолчанию используется образ **`telegrammessenger/proxy:latest`**. Если нужен свой образ (сборка из исходников MTProxy):

```bash
chmod +x install-mtproxy.sh
./install-mtproxy.sh
```

Скрипт собирает образ из `docker-mtproxy/` (builder → runtime) и кладёт результат в `local/mtproxy:latest`.

## Файл конфигурации `~/mtproto_config.txt`

После установки создаётся файл `~/mtproto_config.txt` (права 600) с ключами:
- `SERVER`, `PORT`, `SECRET`, `DOMAIN`, `TAG`, `LINK`, `IMAGE`

Не публикуйте этот файл: в нём секреты прокси.

## Статистика абонентов (`stats-mtproxy.sh`)

Скрипт `stats-mtproxy.sh` собирает длительности TCP‑сессий и строит отчёт по IP.
Также в `report` выводятся накопительные байты `IN/OUT/ALL` по IP клиента (счётчики `nft` в сетевом namespace контейнера).

Команды:

```bash
./stats-mtproxy.sh start     # запустить сборщик в фоне
./stats-mtproxy.sh stop      # остановить
./stats-mtproxy.sh status    # статус
./stats-mtproxy.sh report    # отчёт
./stats-mtproxy.sh diagnose  # диагностика
```

Важно:
- `conntrack` часто требует root, поэтому `start/collect/diagnose` обычно запускают через `sudo`.
- В Docker‑схеме с `-p HOST:443` клиенты могут быть плохо видны на хосте. Поэтому сборщик умеет получать клиентов **изнутри контейнера** через `docker exec`:
  - если в контейнере есть `ss` — используем его;
  - если `ss` нет — читаем `/proc/net/tcp` и берём `ESTABLISHED` на `:443`.

Полезные переменные окружения:
- `MTPROXY_POLL_SEC=1` — период опроса (секунды).
- `MTPROXY_CONTAINER_NAME=mtproto-proxy` — имя контейнера (по умолчанию `mtproto-proxy`).
- `MTPROXY_DOCKER_NO_SUDO=1` — вызывать `docker` без `sudo` (если настроены права).
- `MTPROXY_NO_DOCKER_SS=1` — отключить опрос внутри контейнера.
- `MTPROXY_NO_SS=1` — отключить `ss` на хосте (останется `conntrack` + docker‑источник).
- `MTPROXY_NO_NFT_TRAFFIC=1` — отключить подсчёт байтов через `nft` в netns контейнера.
- `MTPROXY_DEBUG=1` — отладочные счётчики в `collector.log` (сколько потоков найдено/записано за цикл).

Для байтовых счётчиков нужны `nft` и `nsenter` на хосте, а запуск — с правами root (обычно `sudo`).

Сброс статистики:

```bash
sudo ./stats-mtproxy.sh reset trim -y   # убрать служебные IP (Docker/loopback) из sessions.tsv
sudo ./stats-mtproxy.sh reset all  -y   # бэкап и полный сброс sessions.tsv
```

## Устранение неполадок (кратко)

- **Нет подключений**: проверьте, что порт `443` открыт во внешнем фаерволе/SG и на хосте.
- **Секрет/ссылка**: `secret=` в `tg://proxy` должен совпадать с `SECRET` контейнера и тем, что отправили в @MTProxybot.
- **Логи**: `sudo docker logs -f mtproto-proxy`
- **Диагностика статистики**: `sudo ./stats-mtproxy.sh diagnose`

## Безопасность

- Секреты дают доступ к прокси: храните `~/mtproto_config.txt` безопасно.
- Не коммитьте `mtproto_config.txt` и реальные `SECRET`/`TAG`.

## Версионирование

История изменений проекта — в [VERSION.md](VERSION.md).

## Ссылки

- Upstream MTProxy: [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy)

