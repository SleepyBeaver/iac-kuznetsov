#!/usr/bin/env bash

set -euo pipefail            # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта ----
PREFIX=kuznetsov-01                 # префикс имён ресурсов
ZONE_A=ru-central1-a                # зона A
ZONE_B=ru-central1-b                # зона B
CIDR_A=10.11.1.0/24                 # подсеть в зоне A
CIDR_B=10.11.2.0/24                 # подсеть в зоне B
APP_PORT=8003                       # порт, на котором отвечает nginx
GREETING=labwork                    # слово из варианта, оно же на странице
BOOT_SIZE=15                        # загрузочный диск, ГБ — из варианта
DEFAULT_VM_COUNT=2                  # число машин по умолчанию — из варианта
DEFAULT_DISK_SIZE=20                # доп. диск по умолчанию, ГБ — из варианта
IMAGE_FAMILY=ubuntu-2404-lts        # образ машин, одинаковый у всех вариантов

if [ "$#" -gt 2 ]; then
  echo "Использование: bash $0 [число_машин] [размер_диска_ГБ]" >&2
  exit 1
fi
VM_COUNT="${1:-$DEFAULT_VM_COUNT}"
DISK_SIZE="${2:-$DEFAULT_DISK_SIZE}"

if ! [[ "$VM_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Ошибка: число машин должно быть целым числом больше нуля, получено '$VM_COUNT'" >&2
  exit 1
fi
if ! [[ "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "Ошибка: размер диска должен быть целым числом больше нуля, получено '$DISK_SIZE'" >&2
  exit 1
fi
echo "Параметры запуска: машин — $VM_COUNT, доп. диск — $DISK_SIZE ГБ"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> сеть и подсети"
yc vpc network create --name "$PREFIX-net"

yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
  --zone "$ZONE_A" --range "$CIDR_A"
yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
  --zone "$ZONE_B" --range "$CIDR_B"

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < "$SCRIPT_DIR/cloud-init.tpl.yaml" > "$SCRIPT_DIR/cloud-init.yaml"

echo "==> дополнительный диск"
yc compute disk create --name "$PREFIX-data" --zone "$ZONE_A" \
  --size "$DISK_SIZE" --type network-hdd

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))

  DISK_ARGS=()
  if [ "$i" -eq 1 ]; then
    DISK_ARGS=(--attach-disk "disk-name=$PREFIX-data,device-name=data")
  fi

  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$i" \
    --metadata-from-file user-data="$SCRIPT_DIR/cloud-init.yaml" \
    ${DISK_ARGS[@]+"${DISK_ARGS[@]}"}
done

echo "==> целевая группа"
TARGETS=""
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done

yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS

echo "==> балансировщик"
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)

yc load-balancer network-load-balancer create \
  --name "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
  --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/

echo "==> ожидание ответа балансировщика"
LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" \
  --format json | jq -r '.listeners[0].address')

READY=no
for attempt in $(seq 1 60); do
  if curl -fs --max-time 3 "http://$LB_IP" > /dev/null; then
    READY=yes
    break
  fi
  sleep 5
done

if [ "$READY" = yes ]; then
  echo "Стенд готов: http://$LB_IP"
else
  echo "Предупреждение: за 5 минут балансировщик не ответил." >&2
  echo "Проверьте состояние целевой группы (yc load-balancer network-load-balancer target-states)." >&2
fi
echo "LB_IP=$LB_IP"

