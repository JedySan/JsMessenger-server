#!/usr/bin/env bash
# JsMessenger Server — управление.
#
#   ./manage.sh status                  что запущено
#   ./manage.sh check                   проверить всё снаружи: DNS, HTTPS, Matrix, звонки, Jitsi
#   ./manage.sh logs [сервис]           журналы (synapse, livekit, lk-jwt, caddy, jitsi-web…)
#   ./manage.sh adduser ЛОГИН [--admin] [ПАРОЛЬ]   завести пользователя Matrix
#   ./manage.sh passwd ЛОГИН [ПАРОЛЬ]  сменить пароль пользователю Matrix
#   ./manage.sh jitsi-user ЛОГИН [ПАРОЛЬ]           завести пользователя Jitsi (если Jitsi по паролю)
#   ./manage.sh jitsi-auth on|off      Jitsi только для своих / для всех
#   ./manage.sh backup                  резервная копия: база, медиа, ключи, настройки → backups/
#   ./manage.sh update                  обновить образы (версии — в versions.env) и перезапустить
#   ./manage.sh reconfigure             пересоздать конфиги из .env и перезапустить
#   ./manage.sh restart|stop|start
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

cmd=${1:-help}
shift || true

genpass() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-16; }

case $cmd in
  status)
    load_env
    compose ps --format 'table {{.Service}}\t{{.Status}}'
    ;;

  logs)
    load_env
    compose logs --tail 200 -f "$@"
    ;;

  check)
    load_env
    ok=0 fail=0
    chk() { # описание, команда…
      local d=$1
      shift
      if "$@" >/dev/null 2>&1; then
        printf '  %s✓%s %s\n' "$C_G" "$C_0" "$d"
        ok=$((ok + 1))
      else
        printf '  %s✗%s %s\n' "$C_R" "$C_0" "$d"
        fail=$((fail + 1))
      fi
    }
    jget() { curl -fsS --max-time 10 "$1" | grep -q "$2"; }
    say "Проверка снаружи (как увидят клиенты)"
    chk "well-known клиента на $SERVER_NAME" jget "https://$SERVER_NAME/.well-known/matrix/client" "$MATRIX_HOST"
    chk "в well-known указан LiveKit" jget "https://$SERVER_NAME/.well-known/matrix/client" "livekit_service_url"
    chk "well-known федерации на $SERVER_NAME" jget "https://$SERVER_NAME/.well-known/matrix/server" "$MATRIX_HOST:443"
    chk "Matrix API: https://$MATRIX_HOST" jget "https://$MATRIX_HOST/_matrix/client/versions" "versions"
    chk "федерация отвечает" jget "https://$MATRIX_HOST/_matrix/federation/v1/version" "server"
    chk "сервис токенов звонков (lk-jwt)" curl -fsS --max-time 10 "https://$RTC_HOST/livekit/jwt/healthz"
    chk "LiveKit SFU" jget "https://$RTC_HOST/livekit/sfu/" "OK"
    if jitsi_enabled; then
      chk "Jitsi Meet: https://$MEET_HOST" jget "https://$MEET_HOST/" "jitsi"
    fi
    printf '\n  %d из %d в порядке\n' "$ok" "$((ok + fail))"
    if ((fail)); then
      info "Подсказки: ./manage.sh status, ./manage.sh logs caddy (сертификаты), ./manage.sh logs synapse"
      info "Звонки ещё требуют открытых UDP 50100-50200 и 3478 (и TCP 7881) — снаружи их не проверить."
      exit 1
    fi
    ;;

  adduser)
    load_env
    user=${1:?Укажите логин: ./manage.sh adduser ЛОГИН [--admin] [ПАРОЛЬ]}
    shift
    admin=--no-admin pass=""
    for a in "$@"; do
      if [[ $a == --admin ]]; then admin=--admin; else pass=$a; fi
    done
    [[ $user =~ ^[a-z0-9._=-]+$ ]] || die "Логин — латиница в нижнем регистре, цифры и . _ = -"
    [[ -n $pass ]] || pass=$(genpass)
    compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
      -u "$user" -p "$pass" "$admin" http://localhost:8008
    say "Пользователь @$user:$SERVER_NAME, пароль: $pass"
    ;;

  passwd)
    load_env
    user=${1:?Укажите логин: ./manage.sh passwd ЛОГИН [ПАРОЛЬ]}
    pass=${2:-$(genpass)}
    hash=$(compose exec -T synapse hash_password -c /data/homeserver.yaml -p "$pass" | tail -1)
    n=$(compose exec -T postgres psql -U synapse -d synapse -tA \
      -c "UPDATE users SET password_hash='${hash}' WHERE name='@${user}:${SERVER_NAME}' RETURNING name" | grep -c . || true)
    ((n > 0)) || die "Нет пользователя @$user:$SERVER_NAME"
    say "Новый пароль @$user:$SERVER_NAME: $pass"
    info "Открытые сеансы пользователя остаются в силе; выйти везде можно в настройках клиента."
    ;;

  jitsi-user)
    load_env
    jitsi_enabled || die "Jitsi не установлен"
    [[ ${JITSI_AUTH:-0} == 1 ]] || warn "Сейчас Jitsi открыт для всех — пользователи понадобятся после ./manage.sh jitsi-auth on"
    user=${1:?Укажите логин: ./manage.sh jitsi-user ЛОГИН [ПАРОЛЬ]}
    pass=${2:-$(genpass)}
    compose exec -T jitsi-prosody prosodyctl --config /config/prosody.cfg.lua register "$user" meet.jitsi "$pass"
    say "Jitsi: $user / $pass — создавать встречи на https://$MEET_HOST"
    ;;

  jitsi-auth)
    load_env
    jitsi_enabled || die "Jitsi не установлен"
    case ${1:-} in
      on) env_set JITSI_AUTH 1 ;;
      off) env_set JITSI_AUTH 0 ;;
      *) die "./manage.sh jitsi-auth on|off" ;;
    esac
    load_env
    # prosody пересоздаёт конфиг из переменных при старте
    compose up -d --force-recreate jitsi-prosody jitsi-jicofo jitsi-jvb jitsi-web
    say "Jitsi: $([[ $JITSI_AUTH == 1 ]] && echo "встречи создают пользователи (./manage.sh jitsi-user), гости входят по ссылке" || echo "открыт для всех")"
    ;;

  backup)
    load_env
    dir="backups/$(date +%Y-%m-%d_%H%M)"
    mkdir -p "$dir"
    chmod 700 backups
    say "База данных"
    compose exec -T postgres pg_dump -U synapse -Fc synapse >"$dir/synapse.pgdump"
    say "Ключи, медиа и настройки"
    tar -czf "$dir/files.tar.gz" .env config data/synapse data/jitsi 2>/dev/null ||
      tar -czf "$dir/files.tar.gz" .env config data/synapse
    say "Готово: $dir ($(du -sh "$dir" | cut -f1))"
    info "Скопируйте папку на другой компьютер — на этом же сервере она не спасёт при поломке диска."
    ;;

  update)
    load_env
    if [[ -d .git ]]; then
      say "Обновляю сам комплект (git pull)"
      git pull --ff-only || warn "git pull не удался — продолжаю с текущими файлами"
    fi
    # версии образов из versions.env переносим в .env
    while IFS='=' read -r k v; do
      [[ $k =~ ^[A-Z_]+$ ]] && env_set "$k" "$v"
    done <versions.env
    load_env
    render_all
    chown -R 991:991 data/synapse
    say "Скачиваю образы"
    compose pull --quiet
    compose up -d --remove-orphans
    docker image prune -f >/dev/null
    say "Обновлено"
    "$0" status
    ;;

  reconfigure)
    load_env
    render_all
    chown -R 991:991 data/synapse
    compose up -d --remove-orphans
    compose restart caddy synapse livekit
    say "Конфиги пересозданы, сервисы перезапущены (прежние версии — рядом, *.bak)"
    ;;

  restart) load_env; compose restart "$@" ;;
  stop) load_env; compose stop "$@" ;;
  start) load_env; compose up -d "$@" ;;

  help | -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "Неизвестная команда «$cmd». Список: ./manage.sh help" ;;
esac
