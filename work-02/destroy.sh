#!/usr/bin/env bash
set -euo pipefail            # стоп на первой ошибке и на пустой переменной

PREFIX=kuznetsov-01          # префикс из варианта; число машин здесь не нужно

delete_res() {
  local kind=$1 name=$2
  local list
  list=$(yc $kind list --format json)
  if jq -e --arg n "$name" 'any(.[]; .name == $n)' <<< "$list" > /dev/null; then
    echo "  удаляю: $kind $name"
    yc $kind delete "$name"
  else
    echo "  уже нет: $kind $name — пропускаю"
  fi
}

echo "==> балансировщик и целевая группа"
delete_res "load-balancer network-load-balancer" "$PREFIX-lb"
delete_res "load-balancer target-group" "$PREFIX-tg"

echo "==> машины"
VMS=$(yc compute instance list --format json \
  | jq -r --arg p "$PREFIX-app-" '.[] | select((.name // "") | startswith($p)) | .name')
if [ -z "$VMS" ]; then
  echo "  машин с префиксом $PREFIX-app- нет — пропускаю"
fi
for vm in $VMS; do
  echo "  удаляю: compute instance $vm"
  yc compute instance delete "$vm"
done

echo "==> диск"
delete_res "compute disk" "$PREFIX-data"

echo "==> подсети и сеть"
delete_res "vpc subnet" "$PREFIX-subnet-a"
delete_res "vpc subnet" "$PREFIX-subnet-b"
delete_res "vpc network" "$PREFIX-net"

echo "==> готово"

