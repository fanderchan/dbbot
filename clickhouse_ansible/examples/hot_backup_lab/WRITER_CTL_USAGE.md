# writer_ctl.sh 使用说明

## 目的

`writer_ctl.sh` 用于持续向 ClickHouse 写入模拟业务流量，适合：

1. 热备/恢复演练期间验证在线写入是否连续
2. 备份窗口期间观察写入压力与恢复后数据一致性

支持动作：

1. `start`：后台启动写入循环
2. `run`：前台运行写入循环
3. `stop`：停止后台写入器
4. `status`：查看进程状态与最近一分钟写入量

脚本路径：

1. 仓库内：`examples/hot_backup_lab/writer_ctl.sh`
2. 目标机示例：`/opt/ck_hot_backup_lab/writer_ctl.sh`

## 工作机制

每轮会向每个目标库写入三张事实表：

1. `fact_order_item`
2. `fact_user_action`
3. `mysql_slowlog_raw`

脚本只执行 `INSERT`，不做真实 `UPDATE` 或 `DELETE`。

## 参数说明

### 连接参数

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `--host` | ClickHouse 地址 | `127.0.0.1` |
| `--port` | ClickHouse TCP 端口 | `9000` |
| `--user` | 用户名 | `default` |
| `--password` | 密码 | 无 |
| `--db` | 单库模式库名 | `lab_hot_backup` |
| `--dbs` | 多库模式（逗号分隔） | 无 |

`--dbs` 设置后优先级高于 `--db`。

### 写入负载参数

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `--order-batch` | 每轮 `fact_order_item` 行数 | `2000` |
| `--action-batch` | 每轮 `fact_user_action` 行数 | `6000` |
| `--slow-batch` | 每轮 `mysql_slowlog_raw` 行数 | `1200` |
| `--shops` | 店铺维度基数 | `100` |
| `--skus` | SKU 维度基数 | `50000` |
| `--users` | 用户维度基数 | `200000` |
| `--interval` | 循环间隔（秒） | `2` |

### 运行文件

1. PID 文件：`examples/hot_backup_lab/run/writer.pid`
2. 日志文件：`examples/hot_backup_lab/run/writer.log`

## 标准操作

初始化实验库：

```bash
bash examples/hot_backup_lab/init_lab.sh \
  --host 127.0.0.1 --port 9000 --user default --password '<clickhouse_password>' \
  --cluster 'example_3shards_2replicas' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics --reset
```

本机后台启动：

```bash
bash examples/hot_backup_lab/writer_ctl.sh start \
  --host 127.0.0.1 --port 9000 --user default --password '<clickhouse_password>' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics \
  --order-batch 2000 --action-batch 6000 --slow-batch 1200 --interval 2
```

通过 Ansible 在远端启动：

```bash
cd playbooks
ansible ck-src-11-1 -i ../inventory/hosts.deploy.ini \
  -m shell -a "bash /opt/ck_hot_backup_lab/writer_ctl.sh start \
  --host 127.0.0.1 --port 9000 --user default --password '<clickhouse_password>' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics \
  --order-batch 2000 --action-batch 6000 --slow-batch 1200 --interval 2"
```

查看状态：

```bash
bash /opt/ck_hot_backup_lab/writer_ctl.sh status \
  --host 127.0.0.1 --port 9000 --user default --password '<clickhouse_password>' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics
```

停止写入：

```bash
bash /opt/ck_hot_backup_lab/writer_ctl.sh stop
```

## 数据增长模型

默认配置下，大部分事实表和汇总表会持续增长：

1. `fact_order_item_local` / `fact_order_item`
2. `fact_user_action_local` / `fact_user_action`
3. `dws_shop_gmv_1m_local` / `dws_shop_gmv_1m`
4. `dws_slow_digest_1m_local` / `dws_slow_digest_1m`

`mysql_slowlog_raw_local` 具备 `15 DAY DELETE` 的 TTL，会自动回收。

说明：

1. 即使 `mysql_slowlog_raw_local` 有 TTL，`dws_slow_digest_1m_local` 仍会持续增长。
2. 写入落在 `Distributed` 表时，底层 `Replicated*MergeTree` 会按副本数放大实际存储。

## 简单容量估算

示例参数：`order=2000`、`action=6000`、`slow=1200`、`interval=2s`、`dbs=3`

1. 每轮逻辑写入：`27600`
2. 每分钟逻辑写入：`828000`
3. 每日逻辑写入：`1192320000`

单库每日近似值：

1. `fact_order_item`：`86400000`
2. `fact_user_action`：`259200000`
3. `mysql_slowlog_raw`：`51840000`

## 运维建议

1. 长时压测前先评估磁盘余量与后台 Merge 压力。
2. 演练结束后及时执行 `stop`，并按需清理实验库。
3. 如需限制长期容量增长，请为 `fact_*_local` 和 `dws_*_local` 增加 TTL。
