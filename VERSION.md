# Версионирование проекта mtproxy — **1.2.7**

Формат: [Semantic Versioning](https://semver.org/lang/ru/) (`MAJOR.MINOR.PATCH`).

| | |
|--|--|
| **Версия** | **1.2.7** |

---

## 1.2.7 — 2026-03-25

### `stats-mtproxy.sh`

- Исправлен цикл чтения вывода `conntrack -L`: при EOF сборщик больше не зацикливается (высокая нагрузка CPU / внешнее завершение процесса).
- Для пустого `report` добавлена подсказка: если в `collector.pid` записан PID, но процесса уже нет, выводится рекомендация по логу и перезапуску.

---

## 1.2.6 — 2026-03-25

### `stats-mtproxy.sh`

- Пользовательские сообщения и комментарии переведены на английский (как временный шаг против mojibake на Linux после правок на Windows).

### Репозиторий

- Добавлен `.gitattributes`: `*.sh text eol=lf`.

---

## 1.2.5 — 2026-03-25

### `stats-mtproxy.sh`

- Подкоманда **`reset trim|all [ -y ]`**: бэкап `sessions.tsv` и удаление «мусорных» строк или полный сброс.

### `start-mtproxy.sh`

- Пункт **9** → **6) Сброс sessions.tsv**.

### Документация

- **README.md**: примеры `reset`.

---

## 1.2.4 — 2026-03-23

### `stats-mtproxy.sh`

- Игнор **src** 172.16–31, **127.***, **`::ffff:172.16–31.*`** при опросе; эти же IP не попадают в **отчёт** (агрегация в awk).

### Документация

- **README.md**: уточнение фильтра.

---

## 1.2.3 — 2026-03-23

### `stats-mtproxy.sh`

- Сбор по умолчанию: **опрос `conntrack -L`** вместо `-E` (с Docker события часто не попадали в `sessions.tsv`).
- Фильтр **src=172.17.*** (исходящий трафик контейнера).
- **`export PATH`** с `/usr/sbin`; **`nohup env PATH=...`** при фоне.
- **`MTPROXY_COLLECT_EVENTS=1`** — прежний режим `-E`; **`MTPROXY_POLL_SEC`** — период опроса.

### Документация

- **README.md**: описание режимов сбора.

---

## 1.2.2 — 2026-03-23

### `stats-mtproxy.sh`

- Подкоманда **`diagnose`**: пути, conntrack, `ss`, хвост лога.
- **`start`**: проверка `conntrack -L` до фона; через 0.5 с проверка, жив ли PID, иначе хвост лога и выход с ошибкой; `export SUDO_UID` для дочернего `collect`.
- Парсинг conntrack без учёта регистра (`[new]` / `[destroy]`).
- **`status`**: сообщение о «зависшем» PID в файле.

### `start-mtproxy.sh`

- Пункт **9** → **5) Диагностика**.

### Документация

- **README.md**: команда `diagnose`.

---

## 1.2.1 — 2026-03-23

- Скрипт статистики переименован: **`mtproxy-stats.sh`** → **`stats-mtproxy.sh`** (единый шаблон **`*-mtproxy.sh`**).

---

## 1.2.0 — 2026-03-23

### `stats-mtproxy.sh` (новый)

- Сбор длительностей TCP-сессий к порту прокси на хосте через **`conntrack -E`**, запись в **`~/.mtproxy_stats/sessions.tsv`**.
- Подкоманды: **`report`**, **`collect`**, **`start`** (фон + лог), **`stop`**, **`status`**.
- Отчёт: IP, дата первого соединения, время за сегодня / 7 / 30 дней / всего.

### `start-mtproxy.sh`

- Пункт меню **9** — подменю статистики (вызов `stats-mtproxy.sh`).

### Документация

- **README.md**: таблица меню (п. 9), раздел «Статистика абонентов».

---

## 1.1.0 — 2026-03-22

### `docker-mtproxy/entrypoint.sh`

- Добавлен **`--nat-info`**: entrypoint определяет внутренний IP контейнера и внешний IP сервера (из env `EXTERNAL_IP` или через curl) и передаёт `--nat-info <internal>:<external>` бинарнику `mtproto-proxy`. Без этого флага прокси за Docker NAT сообщал Telegram внутренний адрес (`172.17.0.x`), из-за чего клиенты подключались, но не могли обмениваться данными.
- Воркеры по умолчанию **2** (было 1); переопределяется через `WORKERS=N`.

### `start-mtproxy.sh`

- При запуске контейнера передаётся `-e EXTERNAL_IP=${SERVER_IP}`, чтобы entrypoint не тратил время на определение IP через curl.

### Документация

- **README.md**: пункт про `--nat-info` / Docker NAT в разделе «Устранение неполадок»; пункт про `nf_conntrack: table full`.

---

## 1.0.0 — 2026-03-22

Первая зафиксированная версия текущего состава репозитория.

### `start-mtproxy.sh`

- Интерактивное **меню**: установка/переустановка, перезапуск, остановка, удаление, данные подключения, статус, логи (до 100 строк, подсказка `docker logs -f`), **п. 8** — выбор образа Docker (Hub / **`local/mtproxy:latest`**), сохранение в **`~/.mtproxy_docker_image`** и синхронизация **`IMAGE=`** в конфиге.
- Образ по умолчанию: **`telegrammessenger/proxy:latest`**; приоритет: **`DOCKER_IMAGE`** в окружении → файл предпочтений → **`IMAGE=`** в конфиге → Hub.
- Fake TLS secret: **`ee`** + hex(домен) + случайный hex, всего **30** hex-символов после **`ee`**; **одна** строка в Docker `SECRET`, @MTProxybot и `tg://proxy`; домен в hex не длиннее 30 символов.
- Конфиг **`~/mtproto_config.txt`**: `SERVER`, `PORT`, `SECRET`, `DOMAIN`, `TAG`, `LINK`, `IMAGE`; чтение без `source`; пункт «Данные» подхватывает старый **`CLIENT_SECRET`**, если нет **`SECRET`**.
- Авто-IP `https://ifconfig.me/ip`, выбор порта 443 / 8443–8445, проверка занятости `ss`/`lsof`, том **`mtproxy-data:/data`**, `set -Eeuo pipefail`, блок копирования без ANSI.

### `docker-mtproxy/` и `install-mtproxy.sh`

- Сборка бинарника из [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) (`make`), образ с пользователем **`mtproxy`**, `entrypoint.sh`: загрузка `proxy-secret` / `proxy-multi.conf`, запуск `mtproto-proxy -p 8888 -H 443 ...`.
- Опционально `docker save | gzip` для переноса образа.

### Документация

- **`README.md`**: установка, запуск, секреты, Docker, устранение неполадок.

