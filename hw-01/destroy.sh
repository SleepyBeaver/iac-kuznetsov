#!/usr/bin/env bash

set -euo pipefail

HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$HW_DIR/params.sh"
parse_args "$@"

mine() {
  "$@" --format json | jq -r --arg p "$PREFIX" '
    (. // [])[]
    | select((.labels.owner? // "") == $p or ((.name // "") | startswith($p + "-")))
    | "\(.id) \(.name)"'
}

purge() {
  local what=$1; shift
  local found
  found=$(mine "$@")
  if [[ -z "$found" ]]; then
    echo "    $what: своих нет"
    return
  fi
  while read -r id name; do
    "${@:1:$#-1}" delete --id "$id" >/dev/null
    echo "    удалено: $what $name"
  done <<<"$found"
}

echo "уборка стенда $PREFIX"

echo "==> балансировщики";    purge "балансировщик"  yc load-balancer network-load-balancer list
echo "==> целевые группы";    purge "группа"         yc load-balancer target-group list
echo "==> машины";            purge "машина"         yc compute instance list
echo "==> диски";             purge "диск"           yc compute disk list

echo "==> отвязка таблиц маршрутизации от подсетей"
while read -r id name; do
  [[ -z "${id:-}" ]] && continue
  if [[ -n "$(yc vpc subnet get --id "$id" --format json | jq -r '.route_table_id // empty')" ]]; then
    yc vpc subnet update --id "$id" --disassociate-route-table >/dev/null
    echo "    от $name отвязана таблица"
  fi
done <<<"$(mine yc vpc subnet list)"

echo "==> таблицы маршрутизации"; purge "таблица"   yc vpc route-table list
echo "==> NAT-шлюзы";            purge "шлюз"      yc vpc gateway list
echo "==> подсети";              purge "подсеть"   yc vpc subnet list
echo "==> сети";                 purge "сеть"      yc vpc network list
echo "==> публичные адреса";     purge "адрес"     yc vpc address list

echo "готово: ресурсов с префиксом $PREFIX не осталось"

