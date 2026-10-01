#!/usr/bin/env bash
# Практика 1, вариант 01. Журнал команд, создающих и удаляющих ресурсы.

# --- Сервисный аккаунт и роль ---
yc iam service-account get --name kuznetsov-01-sa >/dev/null 2>&1 || \
  yc iam service-account create --name kuznetsov-01-sa

export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name kuznetsov-01-sa --format json | jq -r .id)

yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

# --- Ключ сервисного аккаунта ---
mkdir -p ~/.yc-keys

if [ ! -s ~/.yc-keys/kuznetsov-01-key.json ]; then
  yc iam key create --service-account-name kuznetsov-01-sa \
    --output ~/.yc-keys/kuznetsov-01-key.json
fi

# --- Параметры варианта, сеть и подсеть ---
export PREFIX=kuznetsov-01
export ZONE=ru-central1-a
export CIDR=10.11.1.0/24
export DISK_SIZE=15

yc vpc network create --name "$PREFIX-net"

yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

# --- Машина в своей сети ---
yc compute instance create \
  --name "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --hostname "$PREFIX-web-1" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli

# --- Остановленные машины (прерываемая ВМ может выключиться) ---
# запустить обратно: yc compute instance start <имя-машины>
yc compute instance list --format json | jq -r '.[] | select(.status != "RUNNING") | .name'

# --- Уборка: сначала машины, потом подсеть, потом сеть ---
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"

yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
