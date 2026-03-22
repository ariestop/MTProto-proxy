# Версионирование проекта mtproxy

Формат: [Semantic Versioning](https://semver.org/lang/ru/) (`MAJOR.MINOR.PATCH`). Записи ведутся от новых к старым.

---

## 1.3.2 — 2026-03-22

- **`docker-mtproxy/Dockerfile`**: пользователь **`mtproxy`**, права на `/var/lib/mtproxy` — воркеры mtproxy-0.02 требуют эту учётку; `-u nobody` недостаточно.
- **`docker-mtproxy/entrypoint.sh`**: `chown mtproxy:mtproxy` для конфигов, без `-u nobody`.

---

## 1.3.1 — 2026-03-22

- **`docker-mtproxy/entrypoint.sh`**: **`-u nobody`**, `chown nobody:nogroup` для `proxy-secret` / `proxy-multi.conf` — устраняет `can't find the user mtproxy` / `fatal: cannot change user to (none)` на актуальном `mtproto-proxy`.

---

## 1.3.0 — 2026-03-22

- **`start-mtproxy.sh`**: образ по умолчанию **`local/mtproxy:latest`** (сборка `./install-mtproxy.sh`); Hub `telegrammessenger/proxy:latest` — только через `DOCKER_IMAGE=...`.
- **`README.md`**: обновлена секция про Docker-образ.

---

## 1.2.0 — 2026-03-22

- **`install-mtproxy.sh`**: сборка Docker-образа из официального [MTProxy](https://github.com/TelegramMessenger/MTProxy) (git clone + `make` внутри multi-stage `Dockerfile`), опционально `docker save | gzip`, предложение запустить `start-mtproxy.sh` с `DOCKER_IMAGE`.
- Каталог **`docker-mtproxy/`**: `Dockerfile`, `entrypoint.sh` (переменные `SECRET` / `TAG`, загрузка `proxy-secret` и `proxy-multi.conf` с core.telegram.org).
- Обновлён `README.md`.

---

## 1.1.1 — 2026-03-22

- Функция `emit_copy_block`: вывод секретов и ссылки **без цветов** на отдельных строках после генерации, после успешной установки и в пункте меню «Данные подключения».

---

## 1.1.0 — 2026-03-22

### Скрипт

- Интерактивное **меню**: установка/переустановка, перезапуск, остановка, удаление, данные подключения, статус, логи.
- Учёт уже существующего контейнера перед установкой (остановка/удаление или отмена).
- Если выбранный порт занят — запрос **свободного** порта в цикле.
- Чтение конфига для пункта «Данные подключения» через **`grep`/`cut`**, без `source`.
- Сохранены: раздельные `SERVER_SECRET` / `CLIENT_SECRET`, HTTPS для авто-IP, `ss`/`lsof`, `grep -qxF`, `umask`/`chmod 600`, `DOCKER_IMAGE` из окружения, `log -n`.

### Документация

- Обновлён `README.md` (меню, поведение при занятом порту, безопасное чтение конфига).

---

## 1.0.0 — 2026-03-22

Первая зафиксированная версия документации и текущего поведения скрипта `start-mtproxy.sh`.

### Скрипт

- Разделение **серверного** секрета (`SERVER_SECRET`, 32 hex для Docker и @MTProxybot) и **клиентского** Fake TLS (`CLIENT_SECRET` = `ee` + серверный + hex домена) для ссылки `tg://proxy`.
- Интерактивный ввод: адрес сервера (IPv4 или hostname), порт, домен Fake TLS, TAG (32 hex или пусто).
- Определение внешнего IP через `https://ifconfig.me/ip` с таймаутом и повтором.
- Выбор порта по умолчанию среди 443, 8443–8445 по занятости (`ss` или `lsof`).
- Запуск Docker: `telegrammessenger/proxy` (переопределение через `DOCKER_IMAGE`), том `mtproxy-data:/data`, политика перезапуска `unless-stopped`.
- Сохранение `~/mtproto_config.txt` с `umask 077` и правами `600`.
- Строгий режим shell: `set -Eeuo pipefail`, функция `log` с поддержкой `log -n`.

### Документация

- Добавлены `README.md` (установка, запуск, секреты, troubleshooting) и `VERSION.md`.

---

## 0.x (предыстория, не выпускалась как тег)

Ранние итерации скрипта в репозитории (до 1.0.0):

- **0.3** — смешение одного «длинного» секрета для Docker и клиента; исправлено переходом на пару `SERVER_SECRET` / `CLIENT_SECRET`.
- **0.2** — усиления безопасности: валидация ввода, HTTPS для IP, `chmod 600`, `grep -qxF` для контейнера.
- **0.1** — исходный интерактивный сценарий с запросом IP, порта, домена, регистрацией в боте и TAG.
