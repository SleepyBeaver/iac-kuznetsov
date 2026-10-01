#!/usr/bin/env bash
# Практика 1, самостоятельная часть: стенд из двух машин
set -euo pipefail

# --- Параметры варианта 01 ---
PREFIX=kuznetsov-01
ZONE=ru-central1-a
CIDR=10.11.1.0/24
DISK_SIZE=15
IMAGE_FAMILY=debian-12
# порт приложения 8003 и слово labwork используются при ручной настройке nginx

yc vpc network create --name "$PREFIX-net"

yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

for N in 1 2; do
  yc compute instance create \
    --name "$PREFIX-app-$N" \
    --zone "$ZONE" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$DISK_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$N" \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --labels created-by=script
done

# публичные адреса машин
yc compute instance list --format json \
  | jq -r ".[] | select(.name | startswith(\"$PREFIX-app\")) | \"\(.name)\t\(.network_interfaces[0].primary_v4_address.one_to_one_nat.address)\""
