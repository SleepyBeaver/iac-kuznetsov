# shellcheck shell=bash
# shellcheck disable=SC2034

PREFIX="${PREFIX:-kuznetsov-01}"        # префикс имён ресурсов
ZONE_A="${ZONE_A:-ru-central1-a}"       # зона A
ZONE_B="${ZONE_B:-ru-central1-b}"       # зона B
CIDR_A="${CIDR_A:-10.11.1.0/24}"        # подсеть в зоне A
CIDR_B="${CIDR_B:-10.11.2.0/24}"        # подсеть в зоне B
APP_PORT="${APP_PORT:-8003}"            # порт сервиса
GREETING="${GREETING:-labwork}"         # слово на странице
WEB_COUNT="${WEB_COUNT:-2}"             # число веб-серверов
ENV_NAME="${ENV_NAME:-lab}"             # имя окружения (метка env)
PREEMPTIBLE="${PREEMPTIBLE:-true}"      # прерываемые ВМ: дешевле, но облако может их остановить
BOOT_SIZE="${BOOT_SIZE:-15}"            # загрузочный диск, ГБ
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts}"
SSH_USER="${SSH_USER:-student}"         # пользователь, которого заводит cloud-init
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

usage() {
  cat <<EOF
Использование: $(basename "$0") [параметры]

  --prefix NAME        префикс имён ресурсов         (сейчас: $PREFIX)
  --zone-a ZONE        зона A                        (сейчас: $ZONE_A)
  --zone-b ZONE        зона B                        (сейчас: $ZONE_B)
  --cidr-a CIDR        подсеть в зоне A              (сейчас: $CIDR_A)
  --cidr-b CIDR        подсеть в зоне B              (сейчас: $CIDR_B)
  --port PORT          порт сервиса                  (сейчас: $APP_PORT)
  --word WORD          слово на странице             (сейчас: $GREETING)
  --web-count N        число веб-серверов, N >= 2    (сейчас: $WEB_COUNT)
  --env NAME           имя окружения для меток       (сейчас: $ENV_NAME)
  --no-preemptible     обычные, а не прерываемые ВМ  (сейчас: preemptible=$PREEMPTIBLE)
  -h, --help           эта справка

Каждый параметр можно задать и переменной окружения с тем же смыслом
(PREFIX, ZONE_A, ZONE_B, CIDR_A, CIDR_B, APP_PORT, GREETING, WEB_COUNT,
ENV_NAME, PREEMPTIBLE). Аргумент важнее переменной, переменная важнее
умолчания варианта.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)         PREFIX="${2:?нет значения для $1}";    shift 2 ;;
      --zone-a)         ZONE_A="${2:?нет значения для $1}";    shift 2 ;;
      --zone-b)         ZONE_B="${2:?нет значения для $1}";    shift 2 ;;
      --cidr-a)         CIDR_A="${2:?нет значения для $1}";    shift 2 ;;
      --cidr-b)         CIDR_B="${2:?нет значения для $1}";    shift 2 ;;
      --port)           APP_PORT="${2:?нет значения для $1}";  shift 2 ;;
      --word)           GREETING="${2:?нет значения для $1}";  shift 2 ;;
      --web-count)      WEB_COUNT="${2:?нет значения для $1}"; shift 2 ;;
      --env)            ENV_NAME="${2:?нет значения для $1}";  shift 2 ;;
      --no-preemptible) PREEMPTIBLE=false;                     shift   ;;
      -h|--help)        usage; exit 0 ;;
      *) echo "неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  if ! [[ "$WEB_COUNT" =~ ^[0-9]+$ ]] || (( WEB_COUNT < 2 )); then
    echo "--web-count должен быть целым числом не меньше 2, получено: $WEB_COUNT" >&2
    exit 2
  fi
  if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
    echo "--port должен быть числом, получено: $APP_PORT" >&2
    exit 2
  fi

  NET="$PREFIX-net"
  SUBNET_A="$PREFIX-subnet-a"
  SUBNET_B="$PREFIX-subnet-b"
  NAT_GW="$PREFIX-nat"
  RT="$PREFIX-rt"
  APP_VM="$PREFIX-app"
  TG="$PREFIX-tg"
  LB="$PREFIX-lb"
  LABELS="env=$ENV_NAME,owner=$PREFIX"
}

exists() {
  local err
  if err=$("$@" 2>&1 >/dev/null); then
    return 0
  fi
  if grep -qi 'not found' <<<"$err"; then
    return 1
  fi
  echo "ОШИБКА: проверка существования не удалась: $*" >&2
  echo "$err" >&2
  exit 1
}

web_name() { echo "$PREFIX-web-$1"; }

web_zone()   { if (( $1 % 2 == 1 )); then echo "$ZONE_A";   else echo "$ZONE_B";   fi; }
web_subnet() { if (( $1 % 2 == 1 )); then echo "$SUBNET_A"; else echo "$SUBNET_B"; fi; }

internal_ip() {
  yc compute instance get "$1" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address'
}

external_ip() {
  yc compute instance get "$1" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty'
}

lb_ip() {
  yc load-balancer network-load-balancer get "$LB" --format json \
    | jq -r '.listeners[0].address // empty'
}

