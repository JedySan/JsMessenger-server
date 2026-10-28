#!/usr/bin/env bash
# JsMessenger Server — установка Matrix + LiveKit + Jitsi на чистый сервер одной командой.
#
#   sudo ./install.sh                      — спросит домен и почту
#   sudo ./install.sh -d example.ru -e admin@example.ru -y
#
# Параметры:
#   -d, --domain ДОМЕН        основной домен; поддомены: matrix., rtc., meet.
#   -e, --email ПОЧТА         почта для Let's Encrypt
#   -s, --server-name ИМЯ     имя сервера в адресах (@user:ИМЯ); по умолчанию — основной домен
#       --no-jitsi            без Jitsi Meet
#       --jitsi-auth          Jitsi только для своих: комнаты создают пользователи с паролем
#       --admin ЛОГИН         логин администратора (по умолчанию admin)
#       --ip IP               внешний IP, если определяется неверно
#   -y, --yes                 не задавать вопросов (взять значения по умолчанию)
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

DOMAIN="" EMAIL="" SNAME="" JITSI="" JITSI_AUTH_OPT="" ADMIN="" IP="" YES=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -d | --domain) DOMAIN=${2:?}; shift 2 ;;
    -e | --email) EMAIL=${2:?}; shift 2 ;;
    -s | --server-name) SNAME=${2:?}; shift 2 ;;
    --no-jitsi) JITSI=no; shift ;;
    --jitsi-auth) JITSI_AUTH_OPT=1; shift ;;
    --admin) ADMIN=${2:?}; shift 2 ;;
    --ip) IP=${2:?}; shift 2 ;;
    -y | --yes) YES=1; shift ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. ./install.sh --help)" ;;
  esac
done

ask() { # вопрос, значение по умолчанию → ответ
  local q=$1 def=${2:-} a
  if [[ $YES == 1 || ! -t 0 ]]; then printf '%s' "$def"; return; fi
  read -r -p "    $q${def:+ [$def]}: " a </dev/tty
  printf '%s' "${a:-$def}"
}
yesno() { # вопрос, по умолчанию y|n
  local a
  a=$(ask "$1 (y/n)" "$2")
  [[ $a =~ ^[YyДд] ]]
}

# ---------- 0. проверки ----------
[[ $EUID -eq 0 ]] || die "Запустите от root: sudo ./install.sh"
[[ $(uname -s) == Linux ]] || die "Нужен Linux-сервер"
for t in curl openssl awk ss; do command -v $t >/dev/null || die "Нет программы «$t» — установите её (apt install $t)"; done

say "Docker"
if ! command -v docker >/dev/null; then
  yesno "Docker не установлен. Установить с get.docker.com?" y || die "Без Docker не получится"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "Нет docker compose (плагина v2). Обновите Docker"
systemctl enable --now docker >/dev/null 2>&1 || true
info "$(docker --version)"

# ---------- 1. настройки ----------
FRESH=1
if [[ -f $ENV_FILE ]]; then
  FRESH=0
  load_env
  say "Нашёл прежнюю установку (.env) — беру настройки оттуда"
  info "домен ${DOMAIN}, сервер ${SERVER_NAME}"
else
  say "Настройка"
  [[ -n $DOMAIN ]] || DOMAIN=$(ask "Основной домен (например, example.ru)" "")
  DOMAIN=${DOMAIN,,}
  valid_host "$DOMAIN" || die "Некорректный домен: «$DOMAIN»"
  MATRIX_HOST="matrix.$DOMAIN" RTC_HOST="rtc.$DOMAIN" MEET_HOST="meet.$DOMAIN"
  if [[ -z $SNAME ]]; then
    info "Адреса пользователей могут быть @имя:$DOMAIN (красивее; домен $DOMAIN тоже"
    info "должен указывать на этот сервер) или @имя:$MATRIX_HOST."
    SNAME=$(ask "Имя сервера" "$DOMAIN")
  fi
  SERVER_NAME=${SNAME,,}
  valid_host "$SERVER_NAME" || die "Некорректное имя сервера: «$SERVER_NAME»"
  [[ -n $EMAIL ]] || EMAIL=$(ask "Почта для Let's Encrypt (уведомления о сертификатах)" "admin@$DOMAIN")
  [[ $EMAIL == *@*.* ]] || die "Некорректная почта: «$EMAIL»"
  if [[ -z $JITSI ]]; then
    if yesno "Ставить Jitsi Meet (видеовстречи по ссылке на $MEET_HOST)?" y; then JITSI=yes; else JITSI=no; fi
  fi
  JITSI_AUTH=0
  if [[ $JITSI == yes ]]; then
    if [[ -n $JITSI_AUTH_OPT ]] || yesno "Jitsi только для своих (создавать встречи по паролю, гости — по ссылке)?" n; then JITSI_AUTH=1; fi
  fi
  [[ -n $ADMIN ]] || ADMIN=$(ask "Логин администратора Matrix" "admin")
  [[ $ADMIN =~ ^[a-z0-9._=-]+$ ]] || die "Логин — латиница в нижнем регистре, цифры и . _ = -"
fi

# ---------- 2. внешний IP ----------
if [[ -z $IP ]]; then
  IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
fi
[[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не удалось узнать внешний IP — укажите: --ip 1.2.3.4"
say "Внешний IP: $IP"

# ---------- 3. DNS ----------
HOSTS=("$MATRIX_HOST" "$RTC_HOST")
[[ $SERVER_NAME != "$MATRIX_HOST" ]] && HOSTS=("$SERVER_NAME" "${HOSTS[@]}")
if [[ $FRESH == 1 && $JITSI == yes ]] || { [[ $FRESH == 0 ]] && jitsi_enabled; }; then HOSTS+=("$MEET_HOST"); fi
say "Проверяю DNS"
BAD=()
for h in "${HOSTS[@]}"; do
  # нет записи — getent завершается с ошибкой; при pipefail это не должно останавливать установку
  got=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}' || true)
  if [[ $got == "$IP" ]]; then
    info "✓ $h → $got"
  else
    info "✗ $h → ${got:-нет записи} (нужно $IP)"
    BAD+=("$h")
  fi
done
if ((${#BAD[@]})); then
  warn "Добавьте A-записи на $IP: ${BAD[*]}"
  warn "Без них не выпустятся сертификаты. Можно продолжить — Caddy сам повторит попытку, когда DNS обновится."
  yesno "Продолжить?" n || exit 1
fi

# ---------- 4. порты ----------
say "Проверяю, свободны ли порты"
busy() { # порт, протокол (t|u) → чем занят; пусто, если свободен или занят нашим же комплектом
  local port=$1 proto=$2 line names
  line=$(ss -Hlnp"$proto" "sport = :$port" 2>/dev/null | head -1 || true)
  [[ -z $line ]] && return 0
  if [[ $line == *docker-proxy* || $line == *dockerd* ]]; then
    # порт держит Docker: наш ли это контейнер (проект jsm) или чужой
    names=$(docker ps --filter "publish=$port/$([[ $proto == t ]] && echo tcp || echo udp)" \
      --format '{{.Label "com.docker.compose.project"}}:{{.Names}}' 2>/dev/null | grep -v '^jsm:' | cut -d: -f2- | paste -sd, - || true)
    [[ -z $names ]] && return 0
    printf 'контейнер Docker %s' "$names"
    return 0
  fi
  sed -E 's/.*users:\(\("([^"]+)".*/\1/' <<<"$line"
}
CONFLICT=0
for p in 80/t 443/t 7881/t 3478/u 10000/u 50100/u; do
  who=$(busy "${p%/*}" "${p#*/}")
  if [[ -n $who ]]; then
    warn "Порт ${p%/*}/$([[ ${p#*/} == t ]] && echo tcp || echo udp) занят: $who"
    CONFLICT=1
  fi
done
((CONFLICT == 0)) || die "Порты заняты другими программами. Комплект рассчитан на отдельный сервер: освободите порты (например, systemctl disable --now nginx) или поставьте его на другую машину"
info "✓ 80, 443, 7881, 3478/udp, 10000/udp, 50100-50200/udp"

# ---------- 5. .env и конфиги ----------
if [[ $FRESH == 1 ]]; then
  say "Создаю .env с секретами"
  umask 077
  cat >"$ENV_FILE" <<EOF
# JsMessenger Server — настройки и секреты. Не публикуйте этот файл.
DOMAIN=$DOMAIN
SERVER_NAME=$SERVER_NAME
MATRIX_HOST=$MATRIX_HOST
RTC_HOST=$RTC_HOST
MEET_HOST=$MEET_HOST
ACME_EMAIL=$EMAIL
PUBLIC_IP=$IP
ADMIN_USER=$ADMIN
TZ=$(cat /etc/timezone 2>/dev/null || echo UTC)

# Профили: jitsi — Jitsi Meet
COMPOSE_PROFILES=$([[ $JITSI == yes ]] && echo jitsi)
JITSI_AUTH=$JITSI_AUTH
JITSI_LANG=ru

ENABLE_REGISTRATION=false
MAX_UPLOAD_SIZE=100M

# Секреты (созданы при установке)
POSTGRES_PASSWORD=$(secret 24)
REGISTRATION_SHARED_SECRET=$(secret 32)
MACAROON_SECRET=$(secret 32)
FORM_SECRET=$(secret 32)
LIVEKIT_KEY=$(lk_key)
LIVEKIT_SECRET=$(secret 32)
JICOFO_AUTH_PASSWORD=$(secret 16)
JVB_AUTH_PASSWORD=$(secret 16)

# Версии образов (обновление: поменять здесь и ./manage.sh update)
EOF
  cat versions.env >>"$ENV_FILE"
  umask 022
else
  env_set PUBLIC_IP "$IP"
fi
load_env

say "Пишу конфиги"
mkdir -p data/synapse data/postgres data/caddy config
render_all
chown -R 991:991 data/synapse
info "config/Caddyfile, config/livekit.yaml, config/well-known/, data/synapse/homeserver.yaml"

# ---------- 6. файрвол ----------
PORTS=(80/tcp 443/tcp 443/udp 7881/tcp 3478/udp 50100:50200/udp)
jitsi_enabled && PORTS+=(10000/udp)
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Открываю порты в ufw"
  for p in "${PORTS[@]}"; do ufw allow "$p" >/dev/null; done
  info "${PORTS[*]}"
else
  info "Если у сервера есть внешний файрвол (у хостера), откройте: ${PORTS[*]}"
fi

# ---------- 7. запуск ----------
say "Скачиваю образы (несколько минут при первом запуске)"
compose pull --quiet
if ! ls data/synapse/*.signing.key >/dev/null 2>&1; then
  say "Создаю ключ подписи сервера"
  compose run --rm --no-deps --entrypoint python synapse \
    -m synapse.app.homeserver --config-path /data/homeserver.yaml --generate-keys >/dev/null
  chown -R 991:991 data/synapse
fi
say "Запускаю"
compose up -d --remove-orphans
info "Жду, пока Synapse поднимет базу…"
wait_healthy synapse 240 || { compose logs --tail 60 synapse; die "Synapse не запустился — лог выше"; }

# ---------- 8. администратор ----------
ADMIN_PASS=""
if [[ $FRESH == 1 ]]; then
  ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
  if compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
    -u "$ADMIN_USER" -p "$ADMIN_PASS" --admin http://localhost:8008 >/dev/null 2>&1; then
    say "Создан администратор @$ADMIN_USER:$SERVER_NAME"
  else
    warn "Не удалось создать @$ADMIN_USER — возможно, он уже есть. Новый: ./manage.sh adduser ЛОГИН --admin"
    ADMIN_PASS=""
  fi
fi

# ---------- 9. сертификаты и проверка ----------
say "Жду сертификаты Let's Encrypt"
for _ in $(seq 1 40); do
  curl -fsS --max-time 5 "https://$MATRIX_HOST/_matrix/client/versions" >/dev/null 2>&1 && break
  sleep 3
done
./manage.sh check || true

cat <<EOF

${C_G}${C_B}Готово!${C_0}

  Сервер Matrix:   https://$MATRIX_HOST   (адреса вида @имя:$SERVER_NAME)
  Звонки LiveKit:  https://$RTC_HOST/livekit/jwt
$(jitsi_enabled && echo "  Jitsi Meet:      https://$MEET_HOST")

  Вход в JsMessenger, Element или Element X: сервер ${C_B}$SERVER_NAME${C_0}
EOF
if [[ -n $ADMIN_PASS ]]; then
  cat <<EOF
  Администратор:   ${C_B}$ADMIN_USER${C_0}  пароль ${C_B}$ADMIN_PASS${C_0}
                   ${C_Y}(сохраните — больше он нигде не показывается)${C_0}
EOF
fi
cat <<EOF

  Пользователи:    ./manage.sh adduser ЛОГИН
  Состояние:       ./manage.sh status   |   проверка: ./manage.sh check
  Обновление:      ./manage.sh update   |   резервная копия: ./manage.sh backup
EOF
