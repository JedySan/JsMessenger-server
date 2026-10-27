# JsMessenger Server

Свой сервер Matrix со звонками за 10 минут: одна команда ставит

- **Synapse** + PostgreSQL — сервер Matrix (чаты, файлы, шифрование, федерация);
- **LiveKit** + **lk-jwt-service** — звонки MatrixRTC: аудио, видео, показ экрана в
  [JsMessenger](https://jsmassenger.ru), Element X и Element Call;
- **Jitsi Meet** — видеовстречи по ссылке, в том числе для людей без Matrix;
- **Caddy** — HTTPS: сертификаты Let's Encrypt получает и продлевает сам.

Всё работает в Docker. Регистрация закрыта: пользователей заводит администратор.

```
                       ┌──────────── Caddy :443 (HTTPS) ────────────┐
 example.ru            │ /.well-known/matrix → где сервер и звонки  │
 matrix.example.ru ────┤ /_matrix → Synapse ── PostgreSQL           │
 rtc.example.ru ───────┤ /livekit/jwt → lk-jwt-service (токены)     │
                       │ /livekit/sfu → LiveKit (сигналинг)         │
 meet.example.ru ──────┤ → Jitsi Meet (web, prosody, jicofo)        │
                       └────────────────────────────────────────────┘
 медиа звонков напрямую: LiveKit UDP 50100-50200, TCP 7881, TURN UDP 3478; Jitsi UDP 10000
```

## Что нужно

- Сервер с **Ubuntu 22.04/24.04 или Debian 12**, белый IPv4.
  2 ядра и 2 ГБ памяти без Jitsi, **4 ГБ с Jitsi**. Диск — по объёму файлов в чатах.
- Свободные порты **80 и 443** (на сервере не должно быть nginx/apache на этих портах).
- Домен и **A-записи** на IP сервера:

  | Запись | Для чего |
  |---|---|
  | `example.ru` | имя сервера в адресах `@имя:example.ru` (можно не делать, тогда адреса будут `@имя:matrix.example.ru`) |
  | `matrix.example.ru` | сервер Matrix |
  | `rtc.example.ru` | звонки (LiveKit) |
  | `meet.example.ru` | Jitsi Meet (если нужен) |

  Проще всего одной записью `*.example.ru` плюс `example.ru`.

## Установка

```bash
git clone https://github.com/JedySan/JsMessenger-server.git /opt/jsm-server
cd /opt/jsm-server
sudo ./install.sh
```

Скрипт спросит домен, почту для Let's Encrypt и нужен ли Jitsi, затем сам:

1. поставит Docker, если его нет;
2. проверит DNS и свободные порты;
3. создаст `.env` со случайными паролями и ключами, напишет конфиги;
4. откроет порты в `ufw` (если он включён);
5. запустит всё и заведёт администратора — **пароль покажет один раз**, сохраните его;
6. проверит снаружи, что HTTPS, Matrix, звонки и Jitsi отвечают.

Без вопросов:

```bash
sudo ./install.sh -d example.ru -e admin@example.ru -y            # всё по умолчанию
sudo ./install.sh -d example.ru -e admin@example.ru --no-jitsi -y # без Jitsi
sudo ./install.sh -d example.ru -s matrix.example.ru -y          # адреса @имя:matrix.example.ru
```

Повторный запуск безопасен: возьмёт настройки из `.env`, ничего не сотрёт.

## Вход

В JsMessenger, Element или Element X укажите сервер **`example.ru`** (имя сервера), логин и пароль.
Адрес звонков клиент найдёт сам через `/.well-known/matrix/client`.

Jitsi Meet: `https://meet.example.ru`. В Element комнатные встречи Jitsi тоже пойдут через ваш сервер.

## Управление

```bash
./manage.sh adduser ivan            # новый пользователь, пароль придумает сам
./manage.sh adduser olga --admin    # администратор
./manage.sh passwd ivan             # новый пароль
./manage.sh status                  # что запущено
./manage.sh check                   # проверка снаружи: DNS, HTTPS, Matrix, звонки, Jitsi
./manage.sh logs synapse            # журналы (synapse, livekit, lk-jwt, caddy, jitsi-web…)
./manage.sh backup                  # резервная копия в backups/
./manage.sh update                  # обновить версии и перезапустить
./manage.sh reconfigure             # пересоздать конфиги из .env
./manage.sh jitsi-auth on           # Jitsi только для своих (встречи создают по паролю)
./manage.sh jitsi-user anna         # пользователь Jitsi
```

## Где что лежит

| Путь | Что |
|---|---|
| `.env` | домены, секреты, версии образов — **не публикуйте** |
| `versions.env` | проверенные версии образов; `./manage.sh update` переносит их в `.env` |
| `config/` | Caddyfile, livekit.yaml, well-known — создаются из `.env` |
| `data/synapse/` | `homeserver.yaml`, ключ подписи сервера, загруженные файлы |
| `data/postgres/` | база Synapse |
| `data/caddy/` | сертификаты |
| `backups/` | резервные копии |

Свои правки Synapse вносите в `data/synapse/homeserver.yaml`. Команды `reconfigure` и `update`
пишут его заново, прежняя версия остаётся рядом как `homeserver.yaml.bak`.

## Резервная копия и перенос

`./manage.sh backup` складывает в `backups/ДАТА/` дамп базы (`synapse.pgdump`) и архив
`files.tar.gz` (`.env`, конфиги, ключ подписи, файлы пользователей). Копируйте папку на другой компьютер.

Восстановление на новом сервере:

```bash
git clone https://github.com/JedySan/JsMessenger-server.git /opt/jsm-server && cd /opt/jsm-server
tar -xzf /путь/files.tar.gz                    # .env, config, data/synapse
docker compose up -d postgres && sleep 10
docker compose exec -T postgres pg_restore -U synapse -d synapse --clean --if-exists < /путь/synapse.pgdump
sudo ./install.sh                              # поднимет остальное с прежними настройками
```

Имя сервера (`SERVER_NAME`) после запуска менять нельзя — это часть всех адресов и истории.

## Если что-то не работает

- **Не выпускается сертификат** — `./manage.sh logs caddy`. Почти всегда это DNS (запись ещё
  не разошлась) или закрытый порт 80. Caddy повторяет попытки сам.
- **Звонок соединяется, но нет звука или видео** — закрыты UDP `50100-50200` и `3478` (и TCP `7881`)
  в файрволе хостера. Откройте их в панели провайдера.
- **«Не удалось получить токен звонка»** — `./manage.sh logs lk-jwt`. Сервис проверяет пользователя
  через `https://ИМЯ_СЕРВЕРА/.well-known/matrix/server`; убедитесь, что `./manage.sh check` зелёный.
- **Jitsi не соединяет участников** — закрыт UDP `10000`.
- **Порт 80 или 443 занят** — на сервере уже есть веб-сервер. Этот комплект рассчитан на отдельную машину.

## Лицензия

MIT. Компоненты — под своими лицензиями: Synapse (AGPL-3.0), LiveKit (Apache-2.0),
lk-jwt-service (AGPL-3.0), Jitsi Meet (Apache-2.0), Caddy (Apache-2.0), PostgreSQL.
