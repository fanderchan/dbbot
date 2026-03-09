#!/usr/bin/env bash
set -euo pipefail

ACTION="start"

HOST="127.0.0.1"
PORT="9000"
USER="default"
PASSWORD=""
DB="lab_hot_backup"
DBS=""

ORDER_BATCH=2000
ACTION_BATCH=6000
SLOW_BATCH=1200
SHOP_COUNT=100
SKU_COUNT=50000
USER_COUNT=200000
INTERVAL_SEC=2
TARGET_DBS=()

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${BASE_DIR}/run"
PID_FILE="${RUN_DIR}/writer.pid"
LOG_FILE="${RUN_DIR}/writer.log"

usage() {
  cat <<'USAGE'
用途: 持续向 ClickHouse 写入模拟业务流量（用于热备演练）

命令:
  start       后台启动写入器 (默认)
  run         前台运行写入循环
  stop        停止后台写入器
  status      查看写入器状态与最近一分钟写入量

通用参数:
  --host <host>               ClickHouse 地址 (默认: 127.0.0.1)
  --port <port>               ClickHouse TCP 端口 (默认: 9000)
  --user <user>               用户名 (默认: default)
  --password <password>       密码
  --db <name>                 数据库名 (默认: lab_hot_backup)
  --dbs <a,b,c>               逗号分隔多个数据库名；设置后优先于 --db

写入参数:
  --order-batch <n>           每轮订单行数 (默认: 2000)
  --action-batch <n>          每轮行为日志行数 (默认: 6000)
  --slow-batch <n>            每轮慢日志行数 (默认: 1200)
  --shops <n>                 店铺数 (默认: 100)
  --skus <n>                  SKU 数 (默认: 50000)
  --users <n>                 用户数 (默认: 200000)
  --interval <sec>            每轮间隔秒数 (默认: 2)

示例:
  bash examples/hot_backup_lab/writer_ctl.sh start --host 192.0.2.11 --password '<clickhouse_password>'
  bash examples/hot_backup_lab/writer_ctl.sh start --host 192.0.2.11 --password '<clickhouse_password>' --dbs lab_hot_backup,lab_hot_backup_ext
  bash examples/hot_backup_lab/writer_ctl.sh status --host 192.0.2.11 --password '<clickhouse_password>'
  bash examples/hot_backup_lab/writer_ctl.sh stop
USAGE
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    start|run|stop|status)
      ACTION="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --dbs) DBS="$2"; shift 2 ;;
    --order-batch) ORDER_BATCH="$2"; shift 2 ;;
    --action-batch) ACTION_BATCH="$2"; shift 2 ;;
    --slow-batch) SLOW_BATCH="$2"; shift 2 ;;
    --shops) SHOP_COUNT="$2"; shift 2 ;;
    --skus) SKU_COUNT="$2"; shift 2 ;;
    --users) USER_COUNT="$2"; shift 2 ;;
    --interval) INTERVAL_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "${RUN_DIR}"

if ! command -v clickhouse-client >/dev/null 2>&1; then
  echo "错误: 未找到 clickhouse-client。" >&2
  exit 1
fi

CH_ARGS=(--host "$HOST" --port "$PORT" --user "$USER")
if [[ -n "$PASSWORD" ]]; then
  CH_ARGS+=(--password "$PASSWORD")
fi

chq() {
  clickhouse-client "${CH_ARGS[@]}" --multiquery -q "$1"
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

resolve_target_dbs() {
  local raw_dbs=()
  local db_name=""
  declare -A seen=()
  TARGET_DBS=()

  if [[ -n "$DBS" ]]; then
    IFS=',' read -r -a raw_dbs <<< "$DBS"
    for raw_db in "${raw_dbs[@]}"; do
      db_name="$(trim_spaces "$raw_db")"
      if [[ -z "$db_name" ]]; then
        continue
      fi
      if [[ -z "${seen["$db_name"]+x}" ]]; then
        TARGET_DBS+=("$db_name")
        seen["$db_name"]=1
      fi
    done
  else
    TARGET_DBS=("$DB")
  fi

  if [[ ${#TARGET_DBS[@]} -eq 0 ]]; then
    echo "错误: 未解析到有效数据库名，请检查 --db 或 --dbs 参数。" >&2
    exit 1
  fi
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

insert_orders() {
  local db="$1"
  local base="$2"
  chq "
INSERT INTO ${db}.fact_order_item
(
  line_id,
  order_id,
  user_id,
  shop_id,
  sku_id,
  order_ts,
  order_date,
  qty,
  unit_price,
  gross_amount,
  discount_amount,
  pay_amount,
  pay_channel,
  order_status
)
SELECT
  toUInt64(${base} + number) AS line_id,
  toUInt64(intDiv(${base} + number, 3) + 1) AS order_id,
  toUInt64(1 + cityHash64(number, ${base}, 11) % ${USER_COUNT}) AS user_id,
  toUInt32(1 + cityHash64(number, ${base}, 13) % ${SHOP_COUNT}) AS shop_id,
  toUInt32(1 + cityHash64(number, ${base}, 17) % ${SKU_COUNT}) AS sku_id,
  order_ts,
  toDate(order_ts) AS order_date,
  qty,
  unit_price,
  round(qty * unit_price, 2) AS gross_amount,
  round((qty * unit_price) * discount_ratio, 2) AS discount_amount,
  round((qty * unit_price) * (1 - discount_ratio), 2) AS pay_amount,
  pay_channel,
  order_status
FROM
(
  SELECT
    number,
    now64(3) - toIntervalSecond(cityHash64(number, ${base}, 19) % 30) AS order_ts,
    toUInt8(1 + cityHash64(number, ${base}, 23) % 5) AS qty,
    round(9 + (cityHash64(number, ${base}, 29) % 50000) / 100.0, 2) AS unit_price,
    (cityHash64(number, ${base}, 31) % 20) / 100.0 AS discount_ratio,
    arrayElement(['alipay','wechat','card','wallet'], 1 + cityHash64(number, ${base}, 37) % 4) AS pay_channel,
    arrayElement(['paid','shipped','completed','refund'], 1 + cityHash64(number, ${base}, 41) % 4) AS order_status
  FROM numbers(${ORDER_BATCH})
);
"
}

insert_actions() {
  local db="$1"
  local base="$2"
  chq "
INSERT INTO ${db}.fact_user_action
(
  event_id,
  event_ts,
  event_date,
  user_id,
  session_id,
  shop_id,
  sku_id,
  event_type,
  page,
  referer,
  device,
  latency_ms
)
SELECT
  toUInt64(${base} + 1000000000 + number) AS event_id,
  event_ts,
  toDate(event_ts) AS event_date,
  toUInt64(1 + cityHash64(number, ${base}, 2) % ${USER_COUNT}) AS user_id,
  concat('sess_', toString(intDiv(${base} + number, 25))) AS session_id,
  toUInt32(1 + cityHash64(number, ${base}, 3) % ${SHOP_COUNT}) AS shop_id,
  toUInt32(1 + cityHash64(number, ${base}, 5) % ${SKU_COUNT}) AS sku_id,
  event_type,
  page,
  referer,
  device,
  toUInt16(5 + cityHash64(number, ${base}, 9) % 1200) AS latency_ms
FROM
(
  SELECT
    number,
    now64(3) - toIntervalSecond(cityHash64(number, ${base}, 1) % 60) AS event_ts,
    multiIf(r < 70, 'view', r < 82, 'search', r < 90, 'add_cart', r < 96, 'checkout', 'pay_success') AS event_type,
    multiIf(r < 70, 'product_detail', r < 82, 'search_result', r < 90, 'cart', r < 96, 'checkout_page', 'pay_page') AS page,
    arrayElement(['direct','seo','ads','push','recommend'], 1 + cityHash64(number, ${base}, 7) % 5) AS referer,
    arrayElement(['ios','android','web','mini_program'], 1 + cityHash64(number, ${base}, 8) % 4) AS device
  FROM
  (
    SELECT number, toUInt8(cityHash64(number, ${base}, 6) % 100) AS r
    FROM numbers(${ACTION_BATCH})
  )
);
"
}

insert_slowlogs() {
  local db="$1"
  local base="$2"
  chq "
INSERT INTO ${db}.mysql_slowlog_raw
(
  log_id,
  log_time,
  log_date,
  instance_name,
  db_name,
  digest,
  sample_sql,
  query_time_ms,
  rows_examined,
  rows_sent,
  tmp_disk_tables,
  is_full_scan
)
SELECT
  toUInt64(${base} + 2000000000 + number) AS log_id,
  log_time,
  toDate(log_time) AS log_date,
  instance_name,
  db_name,
  digest,
  sample_sql,
  query_time_ms,
  rows_examined,
  rows_sent,
  tmp_disk_tables,
  is_full_scan
FROM
(
  SELECT
    number,
    now64(3) - toIntervalSecond(cityHash64(number, ${base}, 1) % 120) AS log_time,
    arrayElement(['mysql-prod-131:3306','mysql-prod-132:3306','mysql-prod-133:3306'], 1 + cityHash64(number, ${base}, 2) % 3) AS instance_name,
    arrayElement(['shop','order','member','inventory','payment'], 1 + cityHash64(number, ${base}, 3) % 5) AS db_name,
    lower(hex(cityHash64(number, ${base}, 5) % 200000)) AS digest,
    arrayElement([
      'SELECT * FROM orders WHERE user_id=? ORDER BY id DESC LIMIT 20',
      'SELECT sku_id,sum(pay_amount) FROM order_items WHERE order_date=? GROUP BY sku_id',
      'UPDATE inventory SET stock=stock-? WHERE sku_id=?',
      'SELECT * FROM user_profile WHERE mobile=? LIMIT 1',
      'INSERT INTO payment_log(order_id,amount,channel) VALUES (?,?,?)'
    ], 1 + cityHash64(number, ${base}, 6) % 5) AS sample_sql,
    toUInt32(5 + cityHash64(number, ${base}, 7) % 3500 + if(cityHash64(number, ${base}, 8) % 100 < 3, 12000, 0)) AS query_time_ms,
    toUInt64(10 + cityHash64(number, ${base}, 10) % 300000) AS rows_examined,
    toUInt32(1 + cityHash64(number, ${base}, 11) % 5000) AS rows_sent,
    toUInt8(cityHash64(number, ${base}, 13) % 2) AS tmp_disk_tables,
    toUInt8(cityHash64(number, ${base}, 16) % 100 < 12) AS is_full_scan
  FROM numbers(${SLOW_BATCH})
);
"
}

run_loop() {
  trap 'echo "[writer] 收到退出信号，正在停止"; exit 0' TERM INT

  echo "[writer] 启动前台写入: dbs=$(IFS=,; echo "${TARGET_DBS[*]}"), interval=${INTERVAL_SEC}s, order=${ORDER_BATCH}, action=${ACTION_BATCH}, slow=${SLOW_BATCH}"
  chq "SELECT 1;"
  for target_db in "${TARGET_DBS[@]}"; do
    chq "SELECT throwIf(count() = 0, 'database_not_found: ${target_db}') FROM system.databases WHERE name='${target_db}';" >/dev/null
  done

  local round=0
  while true; do
    local base
    base="$(date +%s%N)"

    for target_db in "${TARGET_DBS[@]}"; do
      insert_orders "$target_db" "$base"
      insert_actions "$target_db" "$base"
      insert_slowlogs "$target_db" "$base"
    done

    round=$((round + 1))
    if (( round % 10 == 0 )); then
      echo "[writer] round=${round} base=${base} time=$(date '+%F %T')"
    fi

    sleep "$INTERVAL_SEC"
  done
}

start_writer() {
  if is_running; then
    echo "写入器已在运行: pid=$(cat "$PID_FILE")"
    exit 0
  fi

  local cmd=(
    "$0" run
    --host "$HOST"
    --port "$PORT"
    --user "$USER"
    --dbs "$(IFS=,; echo "${TARGET_DBS[*]}")"
    --order-batch "$ORDER_BATCH"
    --action-batch "$ACTION_BATCH"
    --slow-batch "$SLOW_BATCH"
    --shops "$SHOP_COUNT"
    --skus "$SKU_COUNT"
    --users "$USER_COUNT"
    --interval "$INTERVAL_SEC"
  )

  if [[ -n "$PASSWORD" ]]; then
    cmd+=(--password "$PASSWORD")
  fi

  nohup "${cmd[@]}" >>"$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"

  echo "写入器已启动: pid=$(cat "$PID_FILE")"
  echo "日志文件: $LOG_FILE"
}

stop_writer() {
  if ! is_running; then
    echo "写入器未运行"
    rm -f "$PID_FILE"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid"

  for _ in {1..20}; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      sleep 0.5
    else
      break
    fi
  done

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "写入器未及时退出，执行强制停止"
    kill -9 "$pid"
  fi

  rm -f "$PID_FILE"
  echo "写入器已停止"
}

status_writer() {
  if is_running; then
    echo "写入器状态: RUNNING (pid=$(cat "$PID_FILE"))"
  else
    echo "写入器状态: STOPPED"
  fi

  echo "---- 最近一分钟写入量 ----"
  for target_db in "${TARGET_DBS[@]}"; do
    echo "[db=${target_db}]"
    if ! chq "
SELECT 'fact_order_item' AS table_name, count() AS rows_1m
FROM ${target_db}.fact_order_item
WHERE order_ts >= now() - INTERVAL 1 MINUTE
UNION ALL
SELECT 'fact_user_action' AS table_name, count() AS rows_1m
FROM ${target_db}.fact_user_action
WHERE event_ts >= now() - INTERVAL 1 MINUTE
UNION ALL
SELECT 'mysql_slowlog_raw' AS table_name, count() AS rows_1m
FROM ${target_db}.mysql_slowlog_raw
WHERE log_time >= now() - INTERVAL 1 MINUTE
ORDER BY table_name;
"; then
      echo "状态查询失败：请确认数据库 ${target_db} 已初始化且连接参数正确。"
    fi
  done

  if [[ -f "$LOG_FILE" ]]; then
    echo "---- 最近日志 ----"
    tail -n 20 "$LOG_FILE"
  fi
}

resolve_target_dbs

case "$ACTION" in
  start) start_writer ;;
  run) run_loop ;;
  stop) stop_writer ;;
  status) status_writer ;;
  *)
    echo "未知命令: ${ACTION}" >&2
    usage
    exit 1
    ;;
esac
