#!/usr/bin/env bash

set -uo pipefail

HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HW_DIR/params.sh"
parse_args "$@"

REQUESTS="${REQUESTS:-20}"
FAIL=0
ok()   { echo "✓ $*"; }
bad()  { echo "✗ $*"; FAIL=1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if ! yc load-balancer network-load-balancer get "$LB" >/dev/null 2>&1; then
  bad "балансировщика $LB нет — стенд не поднят"
  bad "распределение не проверялось: нет балансировщика"
  bad "сервер приложения не проверялся: стенда нет"
  exit 1
fi
LB_IP=$(lb_ip)

CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$LB_IP/")
if [[ "$CODE" == "200" ]]; then
  ok "балансировщик $LB_IP отвечает: $CODE"
else
  bad "балансировщик $LB_IP отвечает: $CODE"
fi

HOSTS=$(for _ in $(seq 1 "$REQUESTS"); do
          curl -s -m 3 "http://$LB_IP/" | grep -o "$GREETING on [a-z0-9-]*" | awk '{print $3}'
        done | sort -u)
N_HOSTS=$(grep -c . <<<"$HOSTS")
HOST_LIST=$(paste -sd, <<<"$HOSTS" | sed 's/,/, /g')
if (( N_HOSTS > 1 )); then
  ok "ответили машины ($N_HOSTS из $WEB_COUNT): $HOST_LIST"
else
  bad "ответили машины ($N_HOSTS из $WEB_COUNT): ${HOST_LIST:-никто}"
fi

APP_IP=$(internal_ip "$APP_VM" 2>/dev/null)
FROM=""; FROM_IP=""
for i in $(seq 1 "$WEB_COUNT"); do
  FROM_IP=$(external_ip "$(web_name "$i")" 2>/dev/null)
  if [[ -n "$FROM_IP" ]]; then FROM=$(web_name "$i"); break; fi
done

if [[ -z "$APP_IP" || "$APP_IP" == "null" ]]; then
  bad "сервера приложения $APP_VM нет"
elif [[ -z "$FROM" ]]; then
  bad "нет веб-сервера с публичным адресом, проверять $APP_VM не с чего"
else
  APP_CODE=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$FROM_IP" \
             "curl -s -o /dev/null -m 5 -w '%{http_code}' http://$APP_IP:$APP_PORT/" 2>/dev/null)
  if [[ "$APP_CODE" == "200" ]]; then
    ok "сервер приложения $APP_IP:$APP_PORT доступен с $FROM: $APP_CODE"
  else
    bad "сервер приложения $APP_IP:$APP_PORT недоступен с $FROM: ${APP_CODE:-нет ответа}"
  fi
fi

if [[ -n "$APP_IP" && "$APP_IP" != "null" ]]; then
  APP_EXT=$(external_ip "$APP_VM" 2>/dev/null)
  if [[ -z "$APP_EXT" ]]; then
    ok "у $APP_VM нет публичного адреса"
  else
    bad "у $APP_VM есть публичный адрес $APP_EXT — он смотрит в интернет"
  fi
fi

exit "$FAIL"

