# hw-01 — демо-стенд для показа продукта

Стенд поднимается одной командой перед показом и сносится одной командой после.
Между показами в облаке не остаётся ничего, за что берут деньги.

| Ресурс | Имя |
|---|---|
| сеть | `kuznetsov-01-net` |
| подсети | `kuznetsov-01-subnet-a` (10.11.1.0/24), `kuznetsov-01-subnet-b` (10.11.2.0/24) |
| NAT-шлюз и таблица | `kuznetsov-01-nat`, `kuznetsov-01-rt` (привязана к subnet-a) |
| веб-серверы | `kuznetsov-01-web-1`, `kuznetsov-01-web-2`, … — зоны чередуются |
| сервер приложения | `kuznetsov-01-app` — только внутренний адрес |
| целевая группа, балансировщик | `kuznetsov-01-tg`, `kuznetsov-01-lb` (80 → 8003) |

Все ресурсы помечены метками `env=lab,owner=kuznetsov-01`.

## Как пользоваться

Команды выполняются из любого каталога.

```bash
bash hw-01/create.sh      # поднять стенд (5–7 минут, ждёт, пока всё станет HEALTHY)
bash hw-01/check.sh       # проверить; код 0 — стенд в норме, 1 — нет
bash hw-01/destroy.sh     # снести всё с префиксом kuznetsov-01
bash hw-01/cost.sh --cpu … --ram … --hdd … --ip … --nlb … --nat …   # цена по ставкам калькулятора
```

`create.sh` можно запускать повторно: уже созданное пропускается, недостающее
доделывается (например, после `--web-count 3` появится третья машина и
добавится в целевую группу).

## Параметры

Умолчания — из варианта 01. Их можно переопределить переменной окружения или
аргументом; **аргумент важнее переменной, переменная важнее умолчания**.

| Аргумент | Переменная | Умолчание |
|---|---|---|
| `--prefix` | `PREFIX` | `kuznetsov-01` |
| `--zone-a` / `--zone-b` | `ZONE_A` / `ZONE_B` | `ru-central1-a` / `ru-central1-b` |
| `--cidr-a` / `--cidr-b` | `CIDR_A` / `CIDR_B` | `10.11.1.0/24` / `10.11.2.0/24` |
| `--port` | `APP_PORT` | `8003` |
| `--word` | `GREETING` | `labwork` |
| `--web-count` | `WEB_COUNT` | `2` (не меньше 2) |
| `--env` | `ENV_NAME` | `lab` |
| `--no-preemptible` | `PREEMPTIBLE=false` | прерываемые ВМ |

Пример: `WEB_COUNT=3 bash hw-01/create.sh --web-count 4` поднимет 4 веб-сервера.
Все три скрипта принимают одни и те же параметры: если стенд поднят с другим
префиксом, его и проверять, и сносить нужно с тем же `--prefix`.

## Что делать, если check.sh вернул 1

| Строка с ✗ | Что это значит | Что делать |
|---|---|---|
| балансировщика нет | стенд не поднят или уже снесён | `bash hw-01/create.sh` |
| балансировщик отвечает не 200 | ни одна машина не прошла проверку состояния | подождать 1–2 минуты после create.sh; затем `yc load-balancer network-load-balancer target-states --name kuznetsov-01-lb --target-group-id <id>` |
| ответила одна машина | сервис жив, но резерва нет: вторая машина UNHEALTHY | зайти на неё: `ssh student@<адрес> 'systemctl status nginx; cloud-init status --long'`; если машину облако остановило (прерываемая) — `yc compute instance start <имя>` |
| сервер приложения недоступен | nginx на app не поднялся или нет маршрута | `cloud-init status` на app через web-1 (`ssh -J student@<web-1> student@<внутр. адрес app>`); если `error` — проверить, что subnet-a привязана к `kuznetsov-01-rt`, удалить app и запустить create.sh ещё раз |
| у app есть публичный адрес | кто-то пересоздал машину руками | удалить `kuznetsov-01-app` и запустить create.sh |

## После уборки

`destroy.sh` ищет ресурсы по метке `owner` и по префиксу имени, поэтому убирает
и то, что create.sh не довёл до конца. Проверить, что ничего не осталось:

```bash
yc compute instance list; yc compute disk list; yc vpc address list
yc vpc network list; yc vpc gateway list
yc load-balancer network-load-balancer list
```

Из сетей должна остаться только `default`.

