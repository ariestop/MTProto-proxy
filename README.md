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

Полный перечень команд `stats-mtproxy.sh`, варианты запуска с `sudo` и таблица переменных окружения — в разделе **«Справочник команд»** ниже.

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

## Справочник команд

Ниже — все основные команды проекта: **как правильно запускать** (с `sudo` или без) и **что делает** каждая команда. Команды выполняйте из каталога с клоном репозитория (или укажите полный путь к скрипту).

### Подготовка скриптов

| Команда | Как запускать | Описание |
|--------|---------------|----------|
| `chmod +x start-mtproxy.sh` | Обычный пользователь, из каталога проекта | Делает главный скрипт исполняемым (один раз после клонирования). |
| `chmod +x install-mtproxy.sh` | Обычный пользователь | Делает скрипт сборки образа исполняемым. |
| `chmod +x stats-mtproxy.sh` | Обычный пользователь | Делает скрипт статистики исполняемым. |

### `start-mtproxy.sh` — меню прокси

| Команда | Как запускать | Описание |
|--------|---------------|----------|
| `./start-mtproxy.sh` | Обычный пользователь; Docker обычно через `sudo docker` внутри скрипта | Интерактивное меню: установка/переустановка контейнера, перезапуск, остановка, удаление, данные подключения, статус, логи, выбор образа Hub/локальный, пункт **9** — статистика (`stats-mtproxy.sh`). |
| `DOCKER_IMAGE=local/mtproxy:latest ./start-mtproxy.sh` | Без `sudo` у скрипта (если настроен Docker без пароля) | Запуск меню с принудительным образом; переменная **`DOCKER_IMAGE`** имеет приоритет над файлом `~/.mtproxy_docker_image` и `IMAGE=` в конфиге. |
| `DOCKER_IMAGE=registry.example.com/mtproxy:tag ./start-mtproxy.sh` | Как выше | Свой образ из частного реестра. |

В меню пункты **1–8, 0** соответствуют установке, жизненному циклу контейнера, данным из конфига, логам и выбору образа; подробности — на экране при запуске.

### `install-mtproxy.sh` — сборка локального образа

| Команда | Как запускать | Описание |
|--------|---------------|----------|
| `./install-mtproxy.sh` | Пользователь с доступом к Docker (`docker` или `sudo docker`) | Сборка образа из `docker-mtproxy/`; тег по умолчанию `local/mtproxy:latest`. |
| `./install-mtproxy.sh -t имя:тег` | Как выше | Задать имя и тег образа вместо значения по умолчанию. |
| `MTPROXY_IMAGE=имя:тег ./install-mtproxy.sh` | Как выше | То же, что `-t`, через переменную окружения. |
| `./install-mtproxy.sh --no-cache` | Как выше | Полная пересборка без кэша слоёв Docker. |
| `./install-mtproxy.sh -h` или `--help` | Любой пользователь | Краткая справка по аргументам. |

После сборки для запуска меню с этим образом: `DOCKER_IMAGE=local/mtproxy:latest ./start-mtproxy.sh` (или ваш тег).

### `stats-mtproxy.sh` — статистика по IP и трафику

Конфиг читается из `~/mtproto_config.txt` (или `MTPROXY_CONFIG_FILE`). Данные сессий: `~/.mtproxy_stats/sessions.tsv`, лог сборщика: `~/.mtproxy_stats/collector.log`.

| Команда | Как запускать | Описание |
|--------|---------------|----------|
| `./stats-mtproxy.sh --help` или `-h` | Любой пользователь | Вывод справки по всем режимам и переменным окружения. |
| `sudo ./stats-mtproxy.sh start` | **Root** (рекомендуется `sudo`) | Запуск фонового сборщика: `conntrack`, при необходимости `ss` и `docker exec`, создание/обновление `nft`-счётчиков в netns контейнера. Без root `conntrack` часто недоступен — сборщик не стартует или не собирает данные. |
| `sudo ./stats-mtproxy.sh stop` | **Root** | Остановка процесса по PID из `~/.mtproxy_stats/collector.pid`. |
| `./stats-mtproxy.sh status` | Обычный пользователь | Показать, запущен ли сборщик (учтён fallback через `ps`, если `kill -0` даёт EPERM без root). |
| `sudo ./stats-mtproxy.sh report` | **Root** для колонок **IN/OUT/ALL** (байты через `nft` + `nsenter`) | Таблица по IP: время сессий из `sessions.tsv` + накопительный трафик. **Без `sudo`** отчёт по времени может быть, а **байты часто остаются 0B**, т.к. чтение `nft` в netns требует привилегий. |
| `./stats-mtproxy.sh report` | Пользователь без root | Допустимо, если нужны только длительности без корректных байтов; при отсутствии прав на `nft` колонки трафика будут нулевыми. |
| `sudo ./stats-mtproxy.sh diagnose` | **Root** (желательно) | Проверка путей, порта из конфига, `conntrack`, `ss`, соединений внутри контейнера, хвоста `collector.log`. |
| `sudo ./stats-mtproxy.sh collect` | **Root** | Сборщик в foreground (отладка); по умолчанию опрос `conntrack -L` в цикле. |
| `MTPROXY_COLLECT_EVENTS=1 sudo ./stats-mtproxy.sh collect` | **Root** | Режим `conntrack -E` (экспериментально; с Docker часто пусто). |
| `sudo ./stats-mtproxy.sh reset trim` | **Root** | Интерактивное подтверждение: удалить из `sessions.tsv` строки со служебными IP (Docker bridge, loopback и т.п.), перед этим бэкап `.bak.время`. |
| `sudo ./stats-mtproxy.sh reset trim -y` | **Root** | То же без запроса подтверждения. |
| `sudo ./stats-mtproxy.sh reset all` | **Root** | Интерактивно: бэкап и полная очистка `sessions.tsv`. |
| `sudo ./stats-mtproxy.sh reset all -y` | **Root** | Полный сброс без вопроса. |

Переменные окружения для `stats-mtproxy.sh` (задаются перед командой, например `MTPROXY_POLL_SEC=1 sudo ./stats-mtproxy.sh start`):

| Переменная | Назначение |
|-----------|------------|
| `MTPROXY_CONFIG_FILE` | Путь к `mtproto_config.txt`, если не `~/mtproto_config.txt`. |
| `MTPROXY_STATS_DIR` | Каталог статистики вместо `~/.mtproxy_stats`. |
| `MTPROXY_POLL_SEC` | Период опроса сборщика в секундах (по умолчанию 3). |
| `MTPROXY_CONTAINER_NAME` | Имя контейнера Docker (по умолчанию `mtproto-proxy`). |
| `MTPROXY_DOCKER_NO_SUDO=1` | Вызывать `docker` без `sudo`. |
| `MTPROXY_NO_DOCKER_SS=1` | Не опрашивать клиентов через `docker exec` внутри контейнера. |
| `MTPROXY_NO_SS=1` | Не использовать `ss` на хосте. |
| `MTPROXY_NO_NFT_TRAFFIC=1` | Отключить подсчёт байтов через `nft`. |
| `MTPROXY_DEBUG=1` | Подробный лог в `collector.log` по циклам опроса. |
| `MTPROXY_LOCAL_IPS` | Пробел‑разделённый список локальных IPv4 для разбора `conntrack`. |
| `MTPROXY_NFT_TABLE`, `MTPROXY_NFT_IN_SET`, `MTPROXY_NFT_OUT_SET` | Имена таблицы и сетов `nft` для трафика (есть значения по умолчанию). |

### Docker (контейнер прокси)

Имя контейнера по умолчанию в проекте: **`mtproto-proxy`**. Команды ниже — с `sudo`, если у пользователя нет группы `docker`.

| Команда | Как запускать | Описание |
|--------|---------------|----------|
| `sudo docker ps` | Пользователь с правами Docker | Список контейнеров; проверка, что `mtproto-proxy` запущен. |
| `sudo docker logs mtproto-proxy` | Как выше | Последние логи контейнера. |
| `sudo docker logs -f mtproto-proxy` | Как выше | Поток логов в реальном времени. |
| `sudo docker restart mtproto-proxy` | Как выше | Перезапуск контейнера без меню `start-mtproxy.sh`. |
| `sudo docker stop mtproto-proxy` | Как выше | Остановка контейнера. |

### Типичные сценарии

| Задача | Последовательность команд |
|--------|---------------------------|
| Первый запуск прокси | `chmod +x start-mtproxy.sh` → `./start-mtproxy.sh` → в меню пункт **1** (установка). |
| Перезапуск только статистики | `sudo ./stats-mtproxy.sh stop` → `sudo ./stats-mtproxy.sh start`. |
| Отчёт с корректными байтами | `sudo ./stats-mtproxy.sh report` (нужны `nft` и `nsenter` на хосте). |
| Сборка своего образа и запуск | `chmod +x install-mtproxy.sh` → `./install-mtproxy.sh` → `DOCKER_IMAGE=local/mtproxy:latest ./start-mtproxy.sh`. |

