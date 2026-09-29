#!/usr/bin/env bash
set -euo pipefail            # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта ----
PREFIX=kuznetsov-01                 # префикс имён ресурсов
ZONE_A=ru-central1-a         # зона A
ZONE_B=ru-central1-b         # зона B
CIDR_A=10.11.1.0/24          # подсеть в зоне A
CIDR_B=10.11.2.0/24          # подсеть в зоне B
APP_PORT=8003                # порт, на котором отвечает nginx
GREETING=labwork             # слово из варианта, оно же на странице
VM_COUNT=2                   # число машин в группе
DISK_SIZE=20                 # дополнительный диск, ГБ — из варианта
BOOT_SIZE=15                 # загрузочный диск, ГБ — из варианта
IMAGE_FAMILY=ubuntu-2404-lts # образ машин, одинаковый у всех вариантов

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
  < work-02/cloud-init.tpl.yaml > work-02/cloud-init.yaml

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$i" \
    --metadata-from-file user-data=work-02/cloud-init.yaml
done

echo "==> дополнительный диск"
yc compute disk create --name "$PREFIX-data" --zone "$ZONE_A" \
  --size "$DISK_SIZE" --type network-hdd

yc compute instance attach-disk "$PREFIX-app-1" \
  --disk-name "$PREFIX-data" \
  --device-name data \
  --auto-delete=false

echo "==> целевая группа"

# собираем список машин: имя подсети и внутренний адрес каждой
TARGETS=""
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done
yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS

echo "==> балансировщик"

# идентификатор целевой группы: балансировщик ссылается на неё по нему
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)

yc load-balancer network-load-balancer create \
  --name "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
  --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/

