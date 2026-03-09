#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="9000"
USER="default"
PASSWORD=""
CLUSTER="example_3shards_2replicas"
DB="lab_ck_biz"

SHOP_COUNT=200
CATEGORY_COUNT=80
SKU_COUNT=80000
USER_COUNT=1000000
DAYS=60

ORDER_ROWS=3000000
ACTION_ROWS=9000000
SLOWLOG_ROWS=3000000

RESET=0

usage() {
  cat <<'USAGE'
用途: 生成 ClickHouse 业务模拟数据（电商 + MySQL 慢日志）

参数:
  --host <host>               ClickHouse 地址 (默认: 127.0.0.1)
  --port <port>               ClickHouse 端口 (默认: 9000)
  --user <user>               用户名 (默认: default)
  --password <password>       密码
  --cluster <name>            集群名 (默认: example_3shards_2replicas)
  --db <name>                 目标库名 (默认: lab_ck_biz)
  --reset                     先 DROP DATABASE 再重建

  --shops <n>                 店铺数量 (默认: 200)
  --categories <n>            类目数量 (默认: 80)
  --skus <n>                  SKU 数量 (默认: 80000)
  --users <n>                 用户数量 (默认: 1000000)
  --days <n>                  时间跨度天数 (默认: 60)

  --orders <n>                订单明细行数 (默认: 3000000)
  --actions <n>               行为日志行数 (默认: 9000000)
  --slowlogs <n>              慢日志行数 (默认: 3000000)

  -h, --help                  显示帮助

示例:
  bash examples/business_demo/generate_ck_business_demo.sh --host 192.0.2.11 --password '<clickhouse_password>' --reset
  bash examples/business_demo/generate_ck_business_demo.sh --orders 500000 --actions 1500000 --slowlogs 500000
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --reset) RESET=1; shift ;;
    --shops) SHOP_COUNT="$2"; shift 2 ;;
    --categories) CATEGORY_COUNT="$2"; shift 2 ;;
    --skus) SKU_COUNT="$2"; shift 2 ;;
    --users) USER_COUNT="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --orders) ORDER_ROWS="$2"; shift 2 ;;
    --actions) ACTION_ROWS="$2"; shift 2 ;;
    --slowlogs) SLOWLOG_ROWS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

CH_ARGS=(--host "$HOST" --port "$PORT" --user "$USER")
if [[ -n "$PASSWORD" ]]; then
  CH_ARGS+=(--password "$PASSWORD")
fi

chq() {
  clickhouse-client "${CH_ARGS[@]}" --multiquery -q "SET distributed_ddl_output_mode='none'; SET insert_distributed_sync=1; $1"
}

echo "[1/8] 连通性检查"
chq "SELECT 'ok' AS status, version() AS clickhouse_version;"

echo "[2/8] 创建数据库与表结构"
if [[ "$RESET" -eq 1 ]]; then
  chq "DROP DATABASE IF EXISTS ${DB} ON CLUSTER '${CLUSTER}' SYNC;"
fi

chq "CREATE DATABASE IF NOT EXISTS ${DB} ON CLUSTER '${CLUSTER}';"

chq "
CREATE TABLE IF NOT EXISTS ${DB}.dim_shop_local ON CLUSTER '${CLUSTER}'
(
  shop_id UInt32,
  shop_name String,
  main_category_id UInt16,
  region LowCardinality(String),
  city LowCardinality(String),
  level LowCardinality(String),
  created_at DateTime,
  updated_at DateTime
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/${DB}/dim_shop_local', '{replica}', updated_at)
ORDER BY shop_id;

CREATE TABLE IF NOT EXISTS ${DB}.dim_shop ON CLUSTER '${CLUSTER}'
AS ${DB}.dim_shop_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dim_shop_local', cityHash64(shop_id));

CREATE TABLE IF NOT EXISTS ${DB}.dim_category_local ON CLUSTER '${CLUSTER}'
(
  category_id UInt16,
  category_name String,
  parent_category_id UInt16,
  layer UInt8,
  updated_at DateTime
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/${DB}/dim_category_local', '{replica}', updated_at)
ORDER BY category_id;

CREATE TABLE IF NOT EXISTS ${DB}.dim_category ON CLUSTER '${CLUSTER}'
AS ${DB}.dim_category_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dim_category_local', cityHash64(category_id));

CREATE TABLE IF NOT EXISTS ${DB}.dim_sku_local ON CLUSTER '${CLUSTER}'
(
  sku_id UInt32,
  shop_id UInt32,
  category_id UInt16,
  brand LowCardinality(String),
  sku_name String,
  listed_at DateTime,
  status LowCardinality(String),
  updated_at DateTime
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/${DB}/dim_sku_local', '{replica}', updated_at)
ORDER BY sku_id;

CREATE TABLE IF NOT EXISTS ${DB}.dim_sku ON CLUSTER '${CLUSTER}'
AS ${DB}.dim_sku_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dim_sku_local', cityHash64(sku_id));

CREATE TABLE IF NOT EXISTS ${DB}.fact_order_item_local ON CLUSTER '${CLUSTER}'
(
  line_id UInt64,
  order_id UInt64,
  user_id UInt64,
  sku_id UInt32,
  shop_id UInt32,
  category_id UInt16,
  order_ts DateTime,
  order_date Date,
  qty UInt8,
  unit_price Float64,
  gross_amount Float64,
  discount_amount Float64,
  pay_amount Float64,
  pay_channel LowCardinality(String),
  order_status LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/fact_order_item_local', '{replica}')
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, shop_id, sku_id, order_id, line_id);

CREATE TABLE IF NOT EXISTS ${DB}.fact_order_item ON CLUSTER '${CLUSTER}'
AS ${DB}.fact_order_item_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'fact_order_item_local', cityHash64(user_id));

CREATE TABLE IF NOT EXISTS ${DB}.fact_user_action_local ON CLUSTER '${CLUSTER}'
(
  event_id UInt64,
  event_ts DateTime,
  event_date Date,
  user_id UInt64,
  session_id String,
  shop_id UInt32,
  sku_id UInt32,
  page LowCardinality(String),
  event_type LowCardinality(String),
  referer LowCardinality(String),
  device LowCardinality(String),
  cost_ms UInt16
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/fact_user_action_local', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type, shop_id, user_id, event_id);

CREATE TABLE IF NOT EXISTS ${DB}.fact_user_action ON CLUSTER '${CLUSTER}'
AS ${DB}.fact_user_action_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'fact_user_action_local', cityHash64(user_id));

CREATE TABLE IF NOT EXISTS ${DB}.fact_inventory_snapshot_local ON CLUSTER '${CLUSTER}'
(
  snapshot_date Date,
  shop_id UInt32,
  sku_id UInt32,
  onhand UInt32,
  reserved UInt32,
  in_transit UInt32,
  safety_stock UInt16
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/fact_inventory_snapshot_local', '{replica}')
PARTITION BY toYYYYMM(snapshot_date)
ORDER BY (snapshot_date, shop_id, sku_id);

CREATE TABLE IF NOT EXISTS ${DB}.fact_inventory_snapshot ON CLUSTER '${CLUSTER}'
AS ${DB}.fact_inventory_snapshot_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'fact_inventory_snapshot_local', cityHash64(sku_id));

CREATE TABLE IF NOT EXISTS ${DB}.mysql_slowlog_raw_local ON CLUSTER '${CLUSTER}'
(
  log_time DateTime64(3),
  log_date Date,
  instance_name LowCardinality(String),
  db_name LowCardinality(String),
  user_name LowCardinality(String),
  digest String,
  sample_sql String,
  sql_type LowCardinality(String),
  query_time_ms UInt32,
  lock_time_ms UInt16,
  rows_examined UInt64,
  rows_sent UInt32,
  tmp_tables UInt8,
  tmp_disk_tables UInt8,
  read_bytes UInt64,
  memory_peak UInt64,
  is_full_scan UInt8,
  success UInt8,
  client_ip String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/mysql_slowlog_raw_local', '{replica}')
PARTITION BY toYYYYMM(log_date)
ORDER BY (log_date, instance_name, digest, log_time)
TTL toDateTime(log_time) + INTERVAL 30 DAY DELETE;

CREATE TABLE IF NOT EXISTS ${DB}.mysql_slowlog_raw ON CLUSTER '${CLUSTER}'
AS ${DB}.mysql_slowlog_raw_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'mysql_slowlog_raw_local', cityHash64(digest));

CREATE TABLE IF NOT EXISTS ${DB}.dws_sku_day_local ON CLUSTER '${CLUSTER}'
(
  dt Date,
  shop_id UInt32,
  sku_id UInt32,
  order_lines UInt64,
  units UInt64,
  gmv Float64,
  paid_gmv Float64
)
ENGINE = ReplicatedSummingMergeTree('/clickhouse/tables/{shard}/${DB}/dws_sku_day_local', '{replica}')
PARTITION BY toYYYYMM(dt)
ORDER BY (dt, shop_id, sku_id);

CREATE TABLE IF NOT EXISTS ${DB}.dws_sku_day ON CLUSTER '${CLUSTER}'
AS ${DB}.dws_sku_day_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dws_sku_day_local', cityHash64(sku_id));

CREATE TABLE IF NOT EXISTS ${DB}.dws_slow_digest_5m_local ON CLUSTER '${CLUSTER}'
(
  bucket_5m DateTime,
  instance_name LowCardinality(String),
  db_name LowCardinality(String),
  digest String,
  cnt UInt64,
  total_query_ms UInt64,
  max_query_ms UInt32,
  rows_examined_sum UInt64,
  tmp_disk_cnt UInt64,
  full_scan_cnt UInt64
)
ENGINE = ReplicatedSummingMergeTree('/clickhouse/tables/{shard}/${DB}/dws_slow_digest_5m_local', '{replica}')
PARTITION BY toYYYYMM(bucket_5m)
ORDER BY (bucket_5m, instance_name, db_name, digest);

CREATE TABLE IF NOT EXISTS ${DB}.dws_slow_digest_5m ON CLUSTER '${CLUSTER}'
AS ${DB}.dws_slow_digest_5m_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dws_slow_digest_5m_local', cityHash64(digest));

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DB}.mv_sku_day_local ON CLUSTER '${CLUSTER}'
TO ${DB}.dws_sku_day_local
AS
SELECT
  order_date AS dt,
  shop_id,
  sku_id,
  count() AS order_lines,
  sum(toUInt64(qty)) AS units,
  sum(gross_amount) AS gmv,
  sumIf(pay_amount, order_status IN ('paid', 'shipped', 'completed')) AS paid_gmv
FROM ${DB}.fact_order_item_local
GROUP BY dt, shop_id, sku_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DB}.mv_slow_digest_5m_local ON CLUSTER '${CLUSTER}'
TO ${DB}.dws_slow_digest_5m_local
AS
SELECT
  toStartOfFiveMinutes(toDateTime(log_time)) AS bucket_5m,
  instance_name,
  db_name,
  digest,
  count() AS cnt,
  sum(toUInt64(query_time_ms)) AS total_query_ms,
  max(query_time_ms) AS max_query_ms,
  sum(rows_examined) AS rows_examined_sum,
  sum(toUInt64(tmp_disk_tables > 0)) AS tmp_disk_cnt,
  sum(toUInt64(is_full_scan)) AS full_scan_cnt
FROM ${DB}.mysql_slowlog_raw_local
GROUP BY bucket_5m, instance_name, db_name, digest;
"

echo "[3/8] 生成维度数据（shop/category/sku）"
chq "
INSERT INTO ${DB}.dim_shop
SELECT
  toUInt32(number + 1) AS shop_id,
  concat('shop_', toString(number + 1)) AS shop_name,
  toUInt16(1 + (number % ${CATEGORY_COUNT})) AS main_category_id,
  arrayElement(['north','south','east','west'], 1 + (number % 4)) AS region,
  arrayElement(['beijing','shanghai','shenzhen','hangzhou','chengdu','wuhan'], 1 + (number % 6)) AS city,
  arrayElement(['gold','silver','bronze'], 1 + (number % 3)) AS level,
  now() - toIntervalDay(90 + (number % 300)) AS created_at,
  now() AS updated_at
FROM numbers(${SHOP_COUNT});

INSERT INTO ${DB}.dim_category
SELECT
  toUInt16(number + 1) AS category_id,
  concat('category_', toString(number + 1)) AS category_name,
  toUInt16(if(number < 10, 0, 1 + (number % 10))) AS parent_category_id,
  toUInt8(if(number < 10, 1, 2)) AS layer,
  now() AS updated_at
FROM numbers(${CATEGORY_COUNT});

INSERT INTO ${DB}.dim_sku
SELECT
  toUInt32(number + 1) AS sku_id,
  toUInt32(1 + cityHash64(number, 11) % ${SHOP_COUNT}) AS shop_id,
  toUInt16(1 + cityHash64(number, 13) % ${CATEGORY_COUNT}) AS category_id,
  arrayElement(['brand_a','brand_b','brand_c','brand_d','brand_e','brand_f'], 1 + cityHash64(number, 17) % 6) AS brand,
  concat('sku_', toString(number + 1)) AS sku_name,
  now() - toIntervalDay(cityHash64(number, 19) % 365) AS listed_at,
  arrayElement(['online','offline'], 1 + cityHash64(number, 23) % 2) AS status,
  now() AS updated_at
FROM numbers(${SKU_COUNT});
"

echo "[4/8] 生成电商订单明细数据 (${ORDER_ROWS} 行)"
chq "
INSERT INTO ${DB}.fact_order_item
SELECT
  toUInt64(number + 1) AS line_id,
  toUInt64(intDiv(number, 3) + 1) AS order_id,
  toUInt64(1 + cityHash64(number, 11) % ${USER_COUNT}) AS user_id,
  toUInt32(1 + cityHash64(number, 13) % ${SKU_COUNT}) AS sku_id,
  toUInt32(1 + cityHash64(number, 17) % ${SHOP_COUNT}) AS shop_id,
  toUInt16(1 + cityHash64(number, 19) % ${CATEGORY_COUNT}) AS category_id,
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
    toDateTime(now() - (cityHash64(number, 23) % (${DAYS} * 86400))) AS order_ts,
    toUInt8(1 + cityHash64(number, 29) % 5) AS qty,
    round(9 + (cityHash64(number, 31) % 50000) / 100.0, 2) AS unit_price,
    (cityHash64(number, 37) % 25) / 100.0 AS discount_ratio,
    arrayElement(['alipay','wechat','card','wallet'], 1 + cityHash64(number, 41) % 4) AS pay_channel,
    arrayElement(['paid','shipped','completed','refund'], 1 + cityHash64(number, 43) % 4) AS order_status
  FROM numbers(${ORDER_ROWS})
);
"

echo "[5/8] 生成电商行为日志 (${ACTION_ROWS} 行)"
chq "
INSERT INTO ${DB}.fact_user_action
SELECT
  toUInt64(number + 1) AS event_id,
  event_ts,
  toDate(event_ts) AS event_date,
  toUInt64(1 + cityHash64(number, 2) % ${USER_COUNT}) AS user_id,
  concat('sess_', toString(intDiv(number, 25))) AS session_id,
  toUInt32(1 + cityHash64(number, 3) % ${SHOP_COUNT}) AS shop_id,
  toUInt32(1 + cityHash64(number, 5) % ${SKU_COUNT}) AS sku_id,
  page,
  event_type,
  referer,
  device,
  toUInt16(5 + cityHash64(number, 9) % 1800) AS cost_ms
FROM
(
  SELECT
    number,
    toDateTime(now() - (cityHash64(number, 1) % (${DAYS} * 86400))) AS event_ts,
    multiIf(r < 70, 'view', r < 82, 'search', r < 90, 'add_cart', r < 96, 'checkout', 'pay_success') AS event_type,
    multiIf(r < 70, 'product_detail', r < 82, 'search_result', r < 90, 'cart', r < 96, 'checkout_page', 'pay_page') AS page,
    arrayElement(['direct','seo','ads','push','recommend'], 1 + cityHash64(number, 7) % 5) AS referer,
    arrayElement(['ios','android','web','mini_program'], 1 + cityHash64(number, 8) % 4) AS device
  FROM
  (
    SELECT number, toUInt8(cityHash64(number, 6) % 100) AS r
    FROM numbers(${ACTION_ROWS})
  )
);
"

echo "[6/8] 生成库存快照数据"
chq "
INSERT INTO ${DB}.fact_inventory_snapshot
SELECT
  toDate(now()) - toIntervalDay(day_offset) AS snapshot_date,
  toUInt32(1 + cityHash64(sku_id, day_offset, 1) % ${SHOP_COUNT}) AS shop_id,
  toUInt32(sku_id) AS sku_id,
  toUInt32(20 + cityHash64(sku_id, day_offset, 2) % 5000) AS onhand,
  toUInt32(cityHash64(sku_id, day_offset, 3) % 500) AS reserved,
  toUInt32(cityHash64(sku_id, day_offset, 4) % 300) AS in_transit,
  toUInt16(10 + cityHash64(sku_id, day_offset, 5) % 200) AS safety_stock
FROM
(
  SELECT
    toUInt32(1 + intDiv(number, ${DAYS})) AS sku_id,
    toUInt16(number % ${DAYS}) AS day_offset
  FROM numbers(${SKU_COUNT} * ${DAYS})
);
"

echo "[7/8] 生成 MySQL 慢日志模拟数据 (${SLOWLOG_ROWS} 行)"
chq "
INSERT INTO ${DB}.mysql_slowlog_raw
SELECT
  log_time,
  toDate(log_time) AS log_date,
  instance_name,
  db_name,
  user_name,
  digest,
  sample_sql,
  sql_type,
  query_time_ms,
  lock_time_ms,
  rows_examined,
  rows_sent,
  tmp_tables,
  tmp_disk_tables,
  read_bytes,
  memory_peak,
  is_full_scan,
  success,
  client_ip
FROM
(
  SELECT
    number,
    toDateTime64(now() - (cityHash64(number, 1) % (${DAYS} * 86400)), 3) AS log_time,
    arrayElement(['mysql-prod-131:3306','mysql-prod-132:3306','mysql-prod-133:3306','mysql-prod-131:3316','mysql-prod-132:3316','mysql-prod-133:3316'], 1 + cityHash64(number, 2) % 6) AS instance_name,
    arrayElement(['shop','order','member','inventory','payment'], 1 + cityHash64(number, 3) % 5) AS db_name,
    arrayElement(['app_ro','app_rw','report','dba'], 1 + cityHash64(number, 4) % 4) AS user_name,
    lower(hex(cityHash64(number, 5) % 50000)) AS digest,
    arrayElement([
      'SELECT * FROM orders WHERE user_id = ? ORDER BY id DESC LIMIT 20',
      'SELECT sku_id, sum(pay_amount) FROM order_items WHERE order_date = ? GROUP BY sku_id',
      'UPDATE inventory SET stock = stock - ? WHERE sku_id = ?',
      'SELECT * FROM user_profile WHERE mobile = ? LIMIT 1',
      'INSERT INTO payment_log(order_id, amount, channel) VALUES (?, ?, ?)'
    ], 1 + cityHash64(number, 6) % 5) AS sample_sql,
    arrayElement(['SELECT','SELECT','UPDATE','SELECT','INSERT'], 1 + cityHash64(number, 6) % 5) AS sql_type,
    toUInt32(5 + cityHash64(number, 7) % 4000 + if(cityHash64(number, 8) % 100 < 2, 20000, 0)) AS query_time_ms,
    toUInt16(cityHash64(number, 9) % 1200) AS lock_time_ms,
    toUInt64(10 + cityHash64(number, 10) % 300000) AS rows_examined,
    toUInt32(1 + cityHash64(number, 11) % 5000) AS rows_sent,
    toUInt8(cityHash64(number, 12) % 4) AS tmp_tables,
    toUInt8(cityHash64(number, 13) % 2) AS tmp_disk_tables,
    toUInt64(4096 + cityHash64(number, 14) % 50000000) AS read_bytes,
    toUInt64(1024 + cityHash64(number, 15) % 200000000) AS memory_peak,
    toUInt8(cityHash64(number, 16) % 100 < 12) AS is_full_scan,
    toUInt8(cityHash64(number, 17) % 100 >= 1) AS success,
    concat('198.18.', toString(1 + cityHash64(number, 18) % 200), '.', toString(1 + cityHash64(number, 19) % 200)) AS client_ip
  FROM numbers(${SLOWLOG_ROWS})
);
"

echo "[8/8] 汇总检查（各表行数，来自 system.parts）"
chq "
SELECT
  table,
  sum(rows) AS rows,
  formatReadableSize(sum(bytes_on_disk)) AS bytes_on_disk
FROM clusterAllReplicas('${CLUSTER}', system.parts)
WHERE database = '${DB}' AND active
GROUP BY table
ORDER BY rows DESC, table ASC;
"

echo "完成: 库 ${DB} 的模拟数据已生成。"
