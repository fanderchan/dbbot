# dbbot 开发指引

## 适用范围
- 本文件定义 `dbbot` 根仓级的助手协作规范。
- 适用范围覆盖：
  - `mysql_ansible/`
  - `clickhouse_ansible/`
  - `monitoring_prometheus_ansible/`
  - `portable-ansible-v0.5.0-py3/`
- 当同仓内不存在更近层级的 `AGENTS.md` 时，默认以本文件为基线。

## 仓库结构
- `mysql_ansible/`：MySQL 生态部署、备份、恢复、运维 Playbook。
- `clickhouse_ansible/`：ClickHouse 集群、NFS、备份、恢复、校验、清理 Playbook。
- `monitoring_prometheus_ansible/`：Prometheus / Alertmanager / Grafana 部署 Playbook。
- `portable-ansible-v0.5.0-py3/`：绿色版 Ansible 运行时。

## /init 基线
- 首先必须读取：
  - `README.md`
  - `VERSION`
- 然后按任务所属子项目补读入口文件：

### MySQL
- `mysql_ansible/playbooks/ansible.cfg`
- `mysql_ansible/playbooks/common_config.yml`
- `mysql_ansible/playbooks/single_node.yml`
- `mysql_ansible/playbooks/master_slave.yml`
- `mysql_ansible/playbooks/mgr.yml`
- `mysql_ansible/playbooks/innodb_cluster.yml`
- `mysql_ansible/playbooks/mha.yml`
- `mysql_ansible/inventory/hosts.ini`

### ClickHouse
- `clickhouse_ansible/playbooks/ansible.cfg`
- `clickhouse_ansible/playbooks/deploy_cluster.yml`
- `clickhouse_ansible/playbooks/deploy_single.yml`
- `clickhouse_ansible/playbooks/backup_cluster.yml`
- `clickhouse_ansible/playbooks/restore_cluster.yml`
- `clickhouse_ansible/playbooks/validate_restore_consistency.yml`
- `clickhouse_ansible/playbooks/uninstall_cluster.yml`
- `clickhouse_ansible/inventory/hosts.deploy.ini`
- `clickhouse_ansible/inventory/hosts.backup.ini`
- `clickhouse_ansible/inventory/hosts.restore.ini`

### Monitoring
- `monitoring_prometheus_ansible/playbooks/ansible.cfg`
- `monitoring_prometheus_ansible/playbooks/common_config.yml`
- `monitoring_prometheus_ansible/playbooks/monitoring_prometheus_deployment.yml`
- `monitoring_prometheus_ansible/inventory/hosts.ini`

## 绿色版 Ansible（统一约定）
- 根仓默认使用绿色版 Ansible：
  - `PORTABLE_ANSIBLE_HOME=/usr/local/dbbot/portable-ansible-v0.5.0-py3`
- 文档面向用户时：
  - 可写 `ansible-playbook`
  - 前提是已执行 `setup_portable_ansible.sh` 并 `source ~/.bashrc`
- 自动化、脚本、非交互执行时：
  - 优先使用显式路径，不依赖 alias：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook ...`
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible ...`
- 版本自检：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook --version`

## 入口约定
- 只有 `playbooks/` 下顶层入口 playbook 允许直接执行。
- `playbooks/tasks/`、`playbooks/pre_tasks/`、`roles/*/tasks/` 下文件默认视为内部复用片段，不单独作为入口。

### MySQL 公开入口
- `single_node.yml`
- `master_slave.yml`
- `mgr.yml`
- `innodb_cluster.yml`
- `innodb_cluster_router.yml`
- `mha.yml`
- `backup_script.yml`
- `backup_script_8.4.yml`
- `restore_pitr_8.4.yml`
- `exporter_install.yml`
- `router_exporter_install.yml`
- `unsafe_uninstall.yml`

### ClickHouse 公开入口
- `deploy_cluster.yml`
- `deploy_single.yml`
- `setup_nfs_server.yml`
- `setup_nfs_client_mount_rc_local.yml`
- `prepare_backup_disk.yml`
- `backup_cluster.yml`
- `restore_cluster.yml`
- `validate_restore_consistency.yml`
- `uninstall_cluster.yml`

### Monitoring 公开入口
- `monitoring_prometheus_deployment.yml`

## 开发规则
- 优先采用可幂等、可回放的 Ansible 方案；非必要不写一次性 shell 逻辑。
- 统一使用 Ansible FQCN 模块（`ansible.builtin.*`）。
- 变量名使用 `lower_snake_case`。
- 拓扑、账号、端口、路径优先放在 inventory 或 `vars/*.yml`，避免写死在 task/template 中。
- 涉及高风险动作时，优先保留：
  - inventory 守卫
  - inventory purpose 守卫
  - 手工确认
- 规则冲突时按以下优先级处理：
  1. 用户明确要求
  2. 仓内已有源码与文档
  3. 通用 Ansible 最佳实践

## 变更要求
- 不要静默修改生产敏感默认值：
  - 端口
  - 默认密码
  - 分片/副本逻辑
  - 备份/恢复对象范围
- 行为变化必须同步更新：
  - 对应 `vars/*.yml`
  - 示例 inventory
  - 相关文档
- 若公开文档位于站点仓：
  - 同步检查 `/vitepress/content`

## 校验清单
- 交付前至少做语法检查：

### MySQL
- `cd /usr/local/dbbot/mysql_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.ini single_node.yml --syntax-check`

### ClickHouse
- `cd /usr/local/dbbot/clickhouse_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check`
- `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check`

### Monitoring
- `cd /usr/local/dbbot/monitoring_prometheus_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check`

- 若改动了 Hugo 文档站内容，还应执行：
  - `cd /vitepress && npm run build`

## 场景性约束

### ClickHouse
- 恢复验收与恢复动作分离：
  - `restore_cluster.yml` 只负责恢复
  - `validate_restore_consistency.yml` 负责跨集群校验
- 对 TTL 表：
  - 不建议直接用源/目标全表 `count()` 做强一致验收
  - 优先使用固定时间窗口或无 TTL 业务表做校验

### MySQL
- 主流程默认围绕：
  - 单实例
  - 主从
  - MGR
  - InnoDB Cluster
  - 备份与恢复
- 若某能力已明确下线或不再支持，不要保留“看起来可用、实际不可用”的入口文档或默认变量。

### Monitoring
- 监控部署与 exporter 注册要分清：
  - Prometheus/Grafana/Alertmanager 部署
  - exporter 安装
  - target 注册与验收

## 变更安全
- 覆盖系统配置时，优先写受控文件，不直接依赖整个系统配置重载。
- 清理/卸载类剧本默认保留手工确认。
- 新增删除、恢复、覆盖类能力时，要明确：
  - 前置条件
  - 风险范围
  - 回滚或重建方式
