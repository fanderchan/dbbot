# ClickHouse 模块说明

本文件只承载 `clickhouse_ansible/` 子树相关的约定。跨模块通用规则（语言、绿色版 Ansible、发版、文档同步等）以仓库根目录 `AGENTS.md` 为准。

## /init 入口文件
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

## 默认实验环境假设
- 默认部署 inventory 位于 `clickhouse_ansible/inventory/hosts.deploy.ini`。
- 默认备份 inventory 位于 `clickhouse_ansible/inventory/hosts.backup.ini`。
- 默认恢复 inventory 位于 `clickhouse_ansible/inventory/hosts.restore.ini`。
- 单节点部署 inventory 位于 `clickhouse_ansible/inventory/hosts.single.ini`。
- 默认安装包目录为 `clickhouse_ansible/downloads/`。

## 公开入口
- `deploy_cluster.yml`
- `deploy_single.yml`
- `setup_nfs_server.yml`
- `setup_nfs_client_mount_rc_local.yml`
- `prepare_backup_disk.yml`
- `backup_cluster.yml`
- `restore_cluster.yml`
- `validate_restore_consistency.yml`
- `uninstall_cluster.yml`

## 编辑规则
- ClickHouse 恢复动作与恢复验收必须分离：
  - `restore_cluster.yml` 只负责恢复。
  - `validate_restore_consistency.yml` 负责跨集群校验。
- 对 TTL 表不建议直接用源/目标全表 `count()` 做强一致验收；优先使用固定时间窗口或无 TTL 业务表做校验。
- 不要把 MySQL 复制、MGR、InnoDB Cluster、MHA 或 Prometheus 部署术语套进 ClickHouse 剧本。
- NFS、备份盘准备、备份、恢复、卸载类剧本必须保留 inventory purpose 守卫和手工确认类守卫。
- 不要把生产密码、私钥、备份存储凭据或 token 写入 inventory 示例、文档或 `AGENTS.md`。

## 校验清单
- `cd /usr/local/dbbot/clickhouse_ansible/playbooks`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.restore.ini validate_restore_consistency.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.deploy.ini uninstall_cluster.yml --syntax-check`
