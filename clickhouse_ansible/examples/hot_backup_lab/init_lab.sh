#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="9000"
USER="default"
PASSWORD=""
CLUSTER="example_3shards_2replicas"
DB="lab_hot_backup"
DBS=""
RESET=0

SHOP_COUNT=100
SKU_COUNT=50000
TARGET_DBS=()

usage() {
  cat <<'USAGE'
用途: 初始化 ClickHouse 热备演练实验库（建表 + 基础维度数据）

参数:
  --host <host>               ClickHouse 地址 (默认: 127.0.0.1)
  --port <port>               ClickHouse TCP 端口 (默认: 9000)
  --user <user>               用户名 (默认: default)
  --password <password>       密码
  --cluster <name>            集群名 (默认: example_3shards_2replicas)
  --db <name>                 数据库名 (默认: lab_hot_backup)
  --dbs <a,b,c>               逗号分隔多个数据库名；设置后优先于 --db
  --shops <n>                 店铺维度数量 (默认: 100)
  --skus <n>                  SKU 维度数量 (默认: 50000)
  --reset                     先删除数据库再重建
  -h, --help                  显示帮助

示例:
  bash examples/hot_backup_lab/init_lab.sh --host 192.0.2.11 --password '<clickhouse_password>' --reset
  bash examples/hot_backup_lab/init_lab.sh --host 192.0.2.11 --password '<clickhouse_password>' --dbs lab_hot_backup,lab_hot_backup_ext --reset
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
    --dbs) DBS="$2"; shift 2 ;;
    --shops) SHOP_COUNT="$2"; shift 2 ;;
    --skus) SKU_COUNT="$2"; shift 2 ;;
    --reset) RESET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v clickhouse-client >/dev/null 2>&1; then
  echo "错误: 未找到 clickhouse-client，请在控制机安装或在任一 ClickHouse 节点执行此脚本。" >&2
  exit 1
fi

CH_ARGS=(--host "$HOST" --port "$PORT" --user "$USER")
if [[ -n "$PASSWORD" ]]; then
  CH_ARGS+=(--password "$PASSWORD")
fi

chq() {
  clickhouse-client "${CH_ARGS[@]}" --multiquery -q "SET distributed_ddl_output_mode='none'; $1"
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

init_one_db() {
  local DB="$1"

  echo "[2/5] 创建数据库与表结构: ${DB}"
  if [[ "$RESET" -eq 1 ]]; then
    chq "DROP DATABASE IF EXISTS ${DB} ON CLUSTER '${CLUSTER}' SYNC;"
  fi

  chq "CREATE DATABASE IF NOT EXISTS ${DB} ON CLUSTER '${CLUSTER}';"

  chq "
CREATE TABLE IF NOT EXISTS ${DB}.dim_shop_local ON CLUSTER '${CLUSTER}'
(
  shop_id UInt32,
  shop_name String,
  region LowCardinality(String),
  level LowCardinality(String),
  updated_at DateTime
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/${DB}/dim_shop_local', '{replica}', updated_at)
ORDER BY shop_id;

CREATE TABLE IF NOT EXISTS ${DB}.dim_shop ON CLUSTER '${CLUSTER}'
AS ${DB}.dim_shop_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dim_shop_local', cityHash64(shop_id));

CREATE TABLE IF NOT EXISTS ${DB}.dim_sku_local ON CLUSTER '${CLUSTER}'
(
  sku_id UInt32,
  shop_id UInt32,
  category_id UInt16,
  brand LowCardinality(String),
  sku_name String,
  list_price Float64,
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
  shop_id UInt32,
  sku_id UInt32,
  order_ts DateTime64(3),
  order_date Date,
  qty UInt8,
  unit_price Float64,
  gross_amount Float64,
  discount_amount Float64,
  pay_amount Float64,
  pay_channel LowCardinality(String),
  order_status LowCardinality(String),
  ingest_time DateTime DEFAULT now()
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
  event_ts DateTime64(3),
  event_date Date,
  user_id UInt64,
  session_id String,
  shop_id UInt32,
  sku_id UInt32,
  event_type LowCardinality(String),
  page LowCardinality(String),
  referer LowCardinality(String),
  device LowCardinality(String),
  latency_ms UInt16,
  ingest_time DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/fact_user_action_local', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type, shop_id, user_id, event_id);

CREATE TABLE IF NOT EXISTS ${DB}.fact_user_action ON CLUSTER '${CLUSTER}'
AS ${DB}.fact_user_action_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'fact_user_action_local', cityHash64(user_id));

CREATE TABLE IF NOT EXISTS ${DB}.mysql_slowlog_raw_local ON CLUSTER '${CLUSTER}'
(
  log_id UInt64,
  log_time DateTime64(3),
  log_date Date,
  instance_name LowCardinality(String),
  db_name LowCardinality(String),
  digest String,
  sample_sql String,
  query_time_ms UInt32,
  rows_examined UInt64,
  rows_sent UInt32,
  tmp_disk_tables UInt8,
  is_full_scan UInt8,
  ingest_time DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${DB}/mysql_slowlog_raw_local', '{replica}')
PARTITION BY toYYYYMM(log_date)
ORDER BY (log_date, instance_name, digest, log_time, log_id)
TTL toDateTime(log_time) + INTERVAL 15 DAY DELETE;

CREATE TABLE IF NOT EXISTS ${DB}.mysql_slowlog_raw ON CLUSTER '${CLUSTER}'
AS ${DB}.mysql_slowlog_raw_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'mysql_slowlog_raw_local', cityHash64(digest));

CREATE TABLE IF NOT EXISTS ${DB}.dws_shop_gmv_1m_local ON CLUSTER '${CLUSTER}'
(
  bucket_1m DateTime,
  shop_id UInt32,
  order_lines UInt64,
  gmv Float64,
  paid_gmv Float64
)
ENGINE = ReplicatedSummingMergeTree('/clickhouse/tables/{shard}/${DB}/dws_shop_gmv_1m_local', '{replica}')
PARTITION BY toYYYYMM(bucket_1m)
ORDER BY (bucket_1m, shop_id);

CREATE TABLE IF NOT EXISTS ${DB}.dws_shop_gmv_1m ON CLUSTER '${CLUSTER}'
AS ${DB}.dws_shop_gmv_1m_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dws_shop_gmv_1m_local', cityHash64(shop_id));

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DB}.mv_shop_gmv_1m_local ON CLUSTER '${CLUSTER}'
TO ${DB}.dws_shop_gmv_1m_local
AS
SELECT
  toStartOfMinute(toDateTime(order_ts)) AS bucket_1m,
  shop_id,
  count() AS order_lines,
  sum(gross_amount) AS gmv,
  sumIf(pay_amount, order_status IN ('paid', 'shipped', 'completed')) AS paid_gmv
FROM ${DB}.fact_order_item_local
GROUP BY bucket_1m, shop_id;

CREATE TABLE IF NOT EXISTS ${DB}.dws_slow_digest_1m_local ON CLUSTER '${CLUSTER}'
(
  bucket_1m DateTime,
  instance_name LowCardinality(String),
  db_name LowCardinality(String),
  digest String,
  cnt UInt64,
  total_query_ms UInt64,
  full_scan_cnt UInt64,
  tmp_disk_cnt UInt64
)
ENGINE = ReplicatedSummingMergeTree('/clickhouse/tables/{shard}/${DB}/dws_slow_digest_1m_local', '{replica}')
PARTITION BY toYYYYMM(bucket_1m)
ORDER BY (bucket_1m, instance_name, db_name, digest);

CREATE TABLE IF NOT EXISTS ${DB}.dws_slow_digest_1m ON CLUSTER '${CLUSTER}'
AS ${DB}.dws_slow_digest_1m_local
ENGINE = Distributed('${CLUSTER}', '${DB}', 'dws_slow_digest_1m_local', cityHash64(digest));

CREATE MATERIALIZED VIEW IF NOT EXISTS ${DB}.mv_slow_digest_1m_local ON CLUSTER '${CLUSTER}'
TO ${DB}.dws_slow_digest_1m_local
AS
SELECT
  toStartOfMinute(toDateTime(log_time)) AS bucket_1m,
  instance_name,
  db_name,
  digest,
  count() AS cnt,
  sum(toUInt64(query_time_ms)) AS total_query_ms,
  sum(toUInt64(is_full_scan)) AS full_scan_cnt,
  sum(toUInt64(tmp_disk_tables > 0)) AS tmp_disk_cnt
FROM ${DB}.mysql_slowlog_raw_local
GROUP BY bucket_1m, instance_name, db_name, digest;
"

  echo "[3/5] 写入维度数据: ${DB}"
  chq "
INSERT INTO ${DB}.dim_shop
SELECT
  toUInt32(number + 1) AS shop_id,
  concat('shop_', toString(number + 1)) AS shop_name,
  arrayElement(['north','south','east','west'], 1 + (number % 4)) AS region,
  arrayElement(['gold','silver','bronze'], 1 + (number % 3)) AS level,
  now() AS updated_at
FROM numbers(${SHOP_COUNT});

INSERT INTO ${DB}.dim_sku
SELECT
  toUInt32(number + 1) AS sku_id,
  toUInt32(1 + cityHash64(number, 11) % ${SHOP_COUNT}) AS shop_id,
  toUInt16(1 + cityHash64(number, 13) % 40) AS category_id,
  arrayElement(['brand_a','brand_b','brand_c','brand_d','brand_e'], 1 + cityHash64(number, 17) % 5) AS brand,
  concat('sku_', toString(number + 1)) AS sku_name,
  round(20 + (cityHash64(number, 19) % 90000) / 100.0, 2) AS list_price,
  now() AS updated_at
FROM numbers(${SKU_COUNT});
"

  echo "[4/5] 核验表已创建: ${DB}"
  chq "
SELECT
  database,
  table,
  engine,
  total_rows
FROM system.tables
WHERE database = '${DB}'
ORDER BY table;
"

  echo "[5/5] 初始化完成: ${DB}"
}

resolve_target_dbs

echo "[1/5] 连通性检查"
chq "SELECT 'ok' AS status, version() AS clickhouse_version;"

echo "目标数据库: $(IFS=,; echo "${TARGET_DBS[*]}")"
for target_db in "${TARGET_DBS[@]}"; do
  init_one_db "$target_db"
done

echo "全部数据库初始化完成。"
