# Версионирование проекта mtproxy — **1.0.0**

Формат: [Semantic Versioning](https://semver.org/lang/ru/) (`MAJOR.MINOR.PATCH`).

| | |
|--|--|
| **Версия** | **1.0.0** |

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

- Сборка бинарника из [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) (`make`), образ с пользователем **`mtproxy`**, `entrypoint.sh`: загрузка `proxy-secret` / `proxy-multi.conf`, запуск `mtproto-proxy -p 8888 -H 443 …`.
- Опционально `docker save | gzip` для переноса образа.

### Документация

- **`README.md`**: установка, запуск, секреты, Docker, устранение неполадок.
