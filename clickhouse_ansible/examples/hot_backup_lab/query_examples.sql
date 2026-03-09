-- 1) 实时写入是否持续
SELECT
  toStartOfMinute(order_ts) AS minute,
  count() AS order_rows,
  round(sum(pay_amount), 2) AS pay_amount
FROM lab_hot_backup.fact_order_item
WHERE order_ts >= now() - INTERVAL 10 MINUTE
GROUP BY minute
ORDER BY minute;

-- 2) 最近 5 分钟店铺 GMV 排行
SELECT
  shop_id,
  round(sum(pay_amount), 2) AS pay_gmv,
  count() AS order_lines
FROM lab_hot_backup.fact_order_item
WHERE order_ts >= now() - INTERVAL 5 MINUTE
GROUP BY shop_id
ORDER BY pay_gmv DESC
LIMIT 20;

-- 3) 漏斗：view -> add_cart -> pay_success
SELECT
  event_type,
  count() AS events,
  uniqExact(user_id) AS uv
FROM lab_hot_backup.fact_user_action
WHERE event_ts >= now() - INTERVAL 30 MINUTE
  AND event_type IN ('view', 'add_cart', 'pay_success')
GROUP BY event_type
ORDER BY events DESC;

-- 4) 最近 30 分钟慢 SQL TOP digest
SELECT
  digest,
  count() AS cnt,
  round(avg(query_time_ms), 2) AS avg_ms,
  max(query_time_ms) AS pmax_ms,
  sum(rows_examined) AS rows_examined_sum
FROM lab_hot_backup.mysql_slowlog_raw
WHERE log_time >= now() - INTERVAL 30 MINUTE
GROUP BY digest
ORDER BY cnt DESC
LIMIT 20;

-- 5) 验证物化视图聚合效果（分钟级）
SELECT
  bucket_1m,
  shop_id,
  order_lines,
  round(gmv, 2) AS gmv,
  round(paid_gmv, 2) AS paid_gmv
FROM lab_hot_backup.dws_shop_gmv_1m
WHERE bucket_1m >= now() - INTERVAL 10 MINUTE
ORDER BY bucket_1m DESC, paid_gmv DESC
LIMIT 50;

-- 6) 备份前后可用于对比的基线统计
SELECT 'fact_order_item' AS table_name, count() AS rows FROM lab_hot_backup.fact_order_item
UNION ALL
SELECT 'fact_user_action' AS table_name, count() AS rows FROM lab_hot_backup.fact_user_action
UNION ALL
SELECT 'mysql_slowlog_raw' AS table_name, count() AS rows FROM lab_hot_backup.mysql_slowlog_raw
ORDER BY table_name;
