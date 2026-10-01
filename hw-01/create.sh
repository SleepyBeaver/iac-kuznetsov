#!/usr/bin/env bash

set -euo pipefail

HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HW_DIR/params.sh"
parse_args "$@"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"

echo "стенд $PREFIX: зоны $ZONE_A/$ZONE_B, порт $APP_PORT, веб-серверов $WEB_COUNT"

echo "==> сеть и подсети"
if exists yc vpc network get "$NET"; then
  echo "    сеть $NET уже есть, пропускаю"
else
  yc vpc network create --name "$NET" --labels "$LABELS" >/dev/null
  echo "    сеть $NET создана"
fi

create_subnet() {   # имя зона диапазон
  if exists yc vpc subnet get "$1"; then
    echo "    подсеть $1 уже есть, пропускаю"
  else
    yc vpc subnet create --name "$1" --network-name "$NET" \
      --zone "$2" --range "$3" --labels "$LABELS" >/dev/null
    echo "    подсеть $1 ($2, $3) создана"
  fi
}
create_subnet "$SUBNET_A" "$ZONE_A" "$CIDR_A"
create_subnet "$SUBNET_B" "$ZONE_B" "$CIDR_B"

echo "==> NAT-шлюз и таблица маршрутизации"
if exists yc vpc gateway get "$NAT_GW"; then
  echo "    шлюз $NAT_GW уже есть, пропускаю"
else
  yc vpc gateway create --name "$NAT_GW" --labels "$LABELS" >/dev/null
  echo "    шлюз $NAT_GW создан"
fi
GW_ID=$(yc vpc gateway get "$NAT_GW" --format json | jq -r .id)

if exists yc vpc route-table get "$RT"; then
  echo "    таблица $RT уже есть, пропускаю"
else
  yc vpc route-table create --name "$RT" --network-name "$NET" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" --labels "$LABELS" >/dev/null
  echo "    таблица $RT создана: 0.0.0.0/0 -> $NAT_GW"
fi
RT_ID=$(yc vpc route-table get "$RT" --format json | jq -r .id)

CUR_RT=$(yc vpc subnet get "$SUBNET_A" --format json | jq -r '.route_table_id // empty')
if [[ "$CUR_RT" == "$RT_ID" ]]; then
  echo "    $SUBNET_A уже ходит через $RT, пропускаю"
else
  yc vpc subnet update "$SUBNET_A" --route-table-id "$RT_ID" >/dev/null
  echo "    $SUBNET_A привязана к $RT"
fi

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat "$SSH_PUBKEY_FILE")
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < "$HW_DIR/cloud-init.tpl.yaml" > "$HW_DIR/cloud-init.yaml"
echo "    $HW_DIR/cloud-init.yaml готов"

PREEMPT_FLAG=()
[[ "$PREEMPTIBLE" == "true" ]] && PREEMPT_FLAG=(--preemptible)

create_vm() {
  local name=$1 zone=$2 subnet=$3 public=$4 nic
  if exists yc compute instance get "$name"; then
    echo "    машина $name уже есть, пропускаю"
    return
  fi
  nic="subnet-name=$subnet"
  [[ "$public" == "yes" ]] && nic="$nic,nat-ip-version=ipv4"
  yc compute instance create \
    --name "$name" --hostname "$name" \
    --zone "$zone" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    "${PREEMPT_FLAG[@]}" \
    --create-boot-disk "image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE,name=$name-boot" \
    --network-interface "$nic" \
    --metadata-from-file user-data="$HW_DIR/cloud-init.yaml" \
    --labels "$LABELS" >/dev/null
  local pub="нет"; [[ "$public" == "yes" ]] && pub="есть"
  echo "    машина $name создана ($zone, публичный адрес: $pub)"
}

echo "==> веб-серверы"
for i in $(seq 1 "$WEB_COUNT"); do
  create_vm "$(web_name "$i")" "$(web_zone "$i")" "$(web_subnet "$i")" yes
done

echo "==> сервер приложения (без публичного адреса)"
create_vm "$APP_VM" "$ZONE_A" "$SUBNET_A" no

echo "==> целевая группа"
TARGETS=()
for i in $(seq 1 "$WEB_COUNT"); do
  TARGETS+=("subnet-name=$(web_subnet "$i"),address=$(internal_ip "$(web_name "$i")")")
done

if exists yc load-balancer target-group get "$TG"; then
  HAVE=$(yc load-balancer target-group get "$TG" --format json | jq -r '.targets[]?.address')
  ADDED=0
  for t in "${TARGETS[@]}"; do
    addr=${t##*address=}
    if ! grep -qx "$addr" <<<"$HAVE"; then
      yc load-balancer target-group add-targets --name "$TG" --target "$t" >/dev/null
      echo "    в $TG добавлен $addr"
      ADDED=1
    fi
  done
  (( ADDED )) || echo "    группа $TG уже есть и полна, пропускаю"
else
  TG_ARGS=()
  for t in "${TARGETS[@]}"; do TG_ARGS+=(--target "$t"); done
  yc load-balancer target-group create --name "$TG" --labels "$LABELS" "${TG_ARGS[@]}" >/dev/null
  echo "    группа $TG создана: ${#TARGETS[@]} машины"
fi
TG_ID=$(yc load-balancer target-group get "$TG" --format json | jq -r .id)

echo "==> балансировщик"
if exists yc load-balancer network-load-balancer get "$LB"; then
  echo "    балансировщик $LB уже есть, пропускаю"
else
  yc load-balancer network-load-balancer create \
    --name "$LB" \
    --region-id ru-central1 \
    --labels "$LABELS" \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/ \
    >/dev/null
  echo "    балансировщик $LB создан: 80 -> $APP_PORT"
fi
LB_IP=$(lb_ip)

echo "==> жду готовности стенда (до ${WAIT_TIMEOUT} с)"
START=$SECONDS
while true; do
  HEALTHY=$(yc load-balancer network-load-balancer target-states --name "$LB" \
              --target-group-id "$TG_ID" --format json \
            | jq '[.[] | select(.status == "HEALTHY")] | length')
  CODE=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$LB_IP/" || true)
  echo "    $((SECONDS - START)) с: HEALTHY $HEALTHY из $WEB_COUNT, балансировщик отвечает: $CODE"
  if [[ "$HEALTHY" -eq "$WEB_COUNT" && "$CODE" == "200" ]]; then
    break
  fi
  if (( SECONDS - START > WAIT_TIMEOUT )); then
    echo "стенд не пришёл в норму за ${WAIT_TIMEOUT} с — смотрите ./check.sh и README" >&2
    exit 1
  fi
  sleep 10
done

echo
echo "стенд готов: http://$LB_IP/"
echo "проверка:    bash $HW_DIR/check.sh"

