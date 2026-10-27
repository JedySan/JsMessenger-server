# shellcheck shell=bash
# Общие функции для install.sh и manage.sh. Подключается через source.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"

# ---------- вывод ----------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_0=
fi
say()  { printf '%s==>%s %s\n' "$C_G$C_B" "$C_0" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y$C_B" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R$C_B" "$C_0" "$*" >&2; exit 1; }

# ---------- .env ----------
load_env() {
  [[ -f "$ENV_FILE" ]] || die "Нет $ENV_FILE — сначала запустите ./install.sh"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# Записать/обновить ключ в .env (значение без кавычек и пробелов)
env_set() {
  local key=$1 val=$2
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    local tmp
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$ENV_FILE" >"$tmp"
    cat "$tmp" >"$ENV_FILE"
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

secret() { openssl rand -hex "${1:-32}"; }
# Ключ LiveKit: буквы и цифры, как у livekit-server generate-keys
lk_key() { printf 'API%s' "$(openssl rand -hex 6)"; }

compose() { (cd "$ROOT" && docker compose "$@"); }

valid_host() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

# ---------- генерация конфигов ----------
# Конфиги пишутся заново из .env; прежние версии сохраняются рядом с суффиксом .bak.
backup_file() { [[ -f $1 ]] && cp -p "$1" "$1.bak"; return 0; }

render_synapse() {
  local dir="$ROOT/data/synapse" f
  mkdir -p "$dir/media_store"
  f="$dir/homeserver.yaml"
  backup_file "$f"
  cat >"$f" <<EOF
# Создано JsMessenger Server. Значения — из .env. Команда «./manage.sh reconfigure» пишет файл
# заново (прежняя версия остаётся рядом как homeserver.yaml.bak) — свои правки переносите оттуда.
server_name: "${SERVER_NAME}"
public_baseurl: "https://${MATRIX_HOST}/"
pid_file: /data/homeserver.pid
signing_key_path: "/data/${SERVER_NAME}.signing.key"
log_config: "/data/log.config"
media_store_path: /data/media_store
report_stats: false

listeners:
  - port: 8008
    type: http
    tls: false
    x_forwarded: true
    bind_addresses: ["0.0.0.0"]
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "${POSTGRES_PASSWORD}"
    database: synapse
    host: postgres
    cp_min: 5
    cp_max: 10

# Регистрация закрыта: пользователей заводит администратор (./manage.sh adduser)
enable_registration: ${ENABLE_REGISTRATION:-false}
registration_shared_secret: "${REGISTRATION_SHARED_SECRET}"
macaroon_secret_key: "${MACAROON_SECRET}"
form_secret: "${FORM_SECRET}"

max_upload_size: ${MAX_UPLOAD_SIZE:-100M}
url_preview_enabled: true
url_preview_ip_range_blacklist:
  - "127.0.0.0/8"
  - "10.0.0.0/8"
  - "172.16.0.0/12"
  - "192.168.0.0/16"
  - "100.64.0.0/10"
  - "192.0.0.0/24"
  - "169.254.0.0/16"
  - "192.88.99.0/24"
  - "198.18.0.0/15"
  - "192.0.2.0/24"
  - "198.51.100.0/24"
  - "203.0.113.0/24"
  - "224.0.0.0/4"
  - "::1/128"
  - "fe80::/10"
  - "fc00::/7"
  - "2001:db8::/32"
  - "ff00::/8"
  - "fec0::/10"

# Новые личные и закрытые чаты — сразу со сквозным шифрованием, как в Element
encryption_enabled_by_default_for_room_type: invite

# Поиск людей по всему серверу, а не только среди соседей по комнатам
user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true

trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true

# ---------- звонки MatrixRTC (Element Call, Element X, JsMessenger) ----------
experimental_features:
  msc3266_enabled: true   # сводка комнаты
  msc4143_enabled: true   # /rtc/transports — где искать LiveKit
  msc4222_enabled: true   # state_after в sync
max_event_delay_duration: 24h   # отложенные события: «вышел из звонка», если пропала связь
rc_message:
  per_second: 0.5
  burst_count: 30
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "https://${RTC_HOST}/livekit/jwt"
EOF
  f="$dir/log.config"
  [[ -f $f ]] || cat >"$f" <<'EOF'
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
handlers:
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.SQL:
    level: WARNING
root:
  level: INFO
  handlers: [console]
disable_existing_loggers: false
EOF
}

render_livekit() {
  local f="$ROOT/config/livekit.yaml"
  mkdir -p "$ROOT/config"
  backup_file "$f"
  cat >"$f" <<EOF
# LiveKit SFU для звонков MatrixRTC. Ключи — из .env.
port: 7880
bind_addresses: [""]
rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: true
  enable_loopback_candidate: false
turn:
  enabled: true
  udp_port: 3478
  domain: ${RTC_HOST}
room:
  # комнаты создаёт только lk-jwt-service для участников Matrix
  auto_create: false
keys:
  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}
logging:
  level: info
EOF
}

render_wellknown() {
  local dir="$ROOT/config/well-known"
  mkdir -p "$dir"
  local jitsi=""
  if jitsi_enabled; then
    jitsi=",
  \"im.vector.riot.jitsi\": { \"preferredDomain\": \"${MEET_HOST}\" }"
  fi
  cat >"$dir/client" <<EOF
{
  "m.homeserver": { "base_url": "https://${MATRIX_HOST}" },
  "org.matrix.msc4143.rtc_foci": [
    { "type": "livekit", "livekit_service_url": "https://${RTC_HOST}/livekit/jwt" }
  ]${jitsi}
}
EOF
  cat >"$dir/server" <<EOF
{ "m.server": "${MATRIX_HOST}:443" }
EOF
}

jitsi_enabled() { [[ ",${COMPOSE_PROFILES:-}," == *",jitsi,"* ]]; }

render_caddy() {
  local f="$ROOT/config/Caddyfile"
  mkdir -p "$ROOT/config"
  backup_file "$f"
  {
    cat <<EOF
# Создано JsMessenger Server. Перезаписывается командой «./manage.sh reconfigure».
{
	email ${ACME_EMAIL}
}

# .well-known/matrix: где сервер и где звонки
(wellknown) {
	handle /.well-known/matrix/* {
		root * /srv
		header Content-Type application/json
		header Access-Control-Allow-Origin *
		file_server
	}
}

${MATRIX_HOST} {
	import wellknown
	handle /_matrix/* {
		reverse_proxy synapse:8008
	}
	handle /_synapse/client/* {
		reverse_proxy synapse:8008
	}
	handle {
		respond "JsMessenger Server: Matrix работает. Клиент: https://jsmassenger.ru" 200
	}
}

${RTC_HOST} {
	# lk-jwt-service сам отдаёт CORS-заголовки — здесь их не добавляем
	handle_path /livekit/jwt/* {
		reverse_proxy lk-jwt:8080
	}
	handle_path /livekit/sfu/* {
		reverse_proxy livekit:7880
	}
	handle {
		respond "MatrixRTC" 200
	}
}
EOF
    if [[ $SERVER_NAME != "$MATRIX_HOST" ]]; then
      cat <<EOF

# Имя сервера (адреса вида @user:${SERVER_NAME}) — отдаём только .well-known,
# остальное перенаправляем на клиент
${SERVER_NAME} {
	import wellknown
	handle {
		redir https://${MATRIX_HOST}{uri}
	}
}
EOF
    fi
    if jitsi_enabled; then
      cat <<EOF

${MEET_HOST} {
	reverse_proxy jitsi-web:8000
}
EOF
    fi
  } >"$f"
}

render_all() {
  render_synapse
  render_livekit
  render_wellknown
  render_caddy
}

# ---------- ожидание ----------
wait_healthy() { # сервис, секунд
  local svc=$1 max=${2:-180} i state
  for ((i = 0; i < max; i += 3)); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q "$svc")" 2>/dev/null || true)
    [[ $state == healthy ]] && return 0
    sleep 3
  done
  return 1
}
