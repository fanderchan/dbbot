# ClickHouse 热备演练示例

这个目录用于备份/恢复演练，不属于主部署链路。它提供三类辅助能力：

1. 初始化实验库与基础维表
2. 后台持续写入模拟业务流量
3. 提供验收 SQL，便于对比备份前后结果

## 目录说明

| 文件 | 作用 |
| --- | --- |
| `init_lab.sh` | 初始化实验库、建表、灌入基础数据 |
| `writer_ctl.sh` | 持续写入控制器（`start/run/stop/status`） |
| `WRITER_CTL_USAGE.md` | `writer_ctl.sh` 的参数说明与运维建议 |
| `query_examples.sql` | 常用验收 SQL |
| `run/` | 运行时生成的 PID 与日志目录，不应提交 |

## 前置条件

1. ClickHouse 集群已部署且连通。
2. 当前环境可执行 `clickhouse-client`。
3. 你已经确认 `host`、`port`、`user`、`password`、`cluster` 等连接参数。

公开仓库中的 IP、密码和集群名均为示例值，请替换为你的真实环境。

## 快速开始

### 单库初始化

```bash
bash examples/hot_backup_lab/init_lab.sh \
  --host 192.0.2.11 \
  --port 9000 \
  --user default \
  --password '<clickhouse_password>' \
  --cluster 'example_3shards_2replicas' \
  --db lab_hot_backup \
  --reset
```

### 启动持续写入

```bash
bash examples/hot_backup_lab/writer_ctl.sh start \
  --host 192.0.2.11 \
  --port 9000 \
  --user default \
  --password '<clickhouse_password>' \
  --db lab_hot_backup \
  --order-batch 3000 \
  --action-batch 9000 \
  --slow-batch 1500 \
  --interval 2
```

### 查看状态

```bash
bash examples/hot_backup_lab/writer_ctl.sh status \
  --host 192.0.2.11 \
  --port 9000 \
  --user default \
  --password '<clickhouse_password>' \
  --db lab_hot_backup
```

### 停止写入

```bash
bash examples/hot_backup_lab/writer_ctl.sh stop
```

## 多库演练

```bash
bash examples/hot_backup_lab/init_lab.sh \
  --host 192.0.2.11 \
  --port 9000 \
  --user default \
  --password '<clickhouse_password>' \
  --cluster 'example_3shards_2replicas' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics \
  --reset
```

```bash
bash examples/hot_backup_lab/writer_ctl.sh start \
  --host 192.0.2.11 \
  --port 9000 \
  --user default \
  --password '<clickhouse_password>' \
  --dbs lab_hot_backup,lab_hot_backup_ext,lab_hot_backup_analytics \
  --interval 2
```

## 推荐演练流程

1. 启动写入器并确认写入持续增长。
2. 执行 `query_examples.sql` 记录基线统计。
3. 运行备份 Playbook。
4. 备份窗口内保持写入器运行，观察是否影响写入。
5. 恢复完成后对比恢复前后统计结果。

## 常见诊断

查看日志：

```bash
tail -f examples/hot_backup_lab/run/writer.log
```

查看进程：

```bash
cat examples/hot_backup_lab/run/writer.pid
ps -fp "$(cat examples/hot_backup_lab/run/writer.pid)"
```

执行验证 SQL：

```bash
clickhouse-client --host 192.0.2.11 --password '<clickhouse_password>' --multiquery < examples/hot_backup_lab/query_examples.sql
```

## 清理实验数据

```sql
DROP DATABASE IF EXISTS lab_hot_backup ON CLUSTER 'example_3shards_2replicas' SYNC;
```

多库清理时，请按库名逐个执行 `DROP DATABASE ... ON CLUSTER ... SYNC`。

## 相关文件

1. `examples/hot_backup_lab/WRITER_CTL_USAGE.md`
2. `playbooks/backup_cluster.yml`
3. `playbooks/restore_cluster.yml`
4. `playbooks/validate_restore_consistency.yml`
