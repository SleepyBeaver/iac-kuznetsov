#!/usr/bin/env bash
# Сносит всё, что создал create.sh
set -euo pipefail

PREFIX=kuznetsov-01

yc compute instance delete "$PREFIX-app-1"
yc compute instance delete "$PREFIX-app-2"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"

# проверка: списки должны быть пустыми, из сетей только default
yc compute instance list
yc vpc network list
yc compute disk list
