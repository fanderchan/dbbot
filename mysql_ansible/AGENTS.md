# MySQL 模块说明

本文件只承载 `mysql_ansible/` 子树相关的约定。跨模块通用规则（语言、绿色版 Ansible、发版、文档同步等）以仓库根目录 `AGENTS.md` 为准。

## /init 入口文件
- `mysql_ansible/playbooks/ansible.cfg`
- `mysql_ansible/playbooks/common_config.yml`
- `mysql_ansible/playbooks/advanced_config.yml`
- `mysql_ansible/playbooks/single_node.yml`
- `mysql_ansible/playbooks/master_slave.yml`
- `mysql_ansible/playbooks/mgr.yml`
- `mysql_ansible/playbooks/innodb_cluster.yml`
- `mysql_ansible/playbooks/mha.yml`
- `mysql_ansible/playbooks/mha_go.yml`
- `mysql_ansible/inventory/hosts.ini`
- `mysql_ansible/inventory/test/hosts.ini`

## 默认实验环境假设
- 官方三节点 MySQL 测试机清单位于 `mysql_ansible/inventory/test/hosts.ini`。
- 官方三节点 MySQL 测试机为 `192.168.161.11`、`192.168.161.12`、`192.168.161.13`。
- Agent 做官方端到端测试、发版回归或复现用户指定测试环境时，应优先读取并使用 `mysql_ansible/inventory/test/hosts.ini`；只有在用户明确指定其他环境时才改用别的 inventory。
- 默认 inventory 位于 `mysql_ansible/inventory/hosts.ini`。
- 默认安装包目录为 `mysql_ansible/downloads/`。

## 公开入口
- `single_node.yml`
- `master_slave.yml`
- `keepalived_master_slave.yml`
- `mgr.yml`
- `innodb_cluster.yml`
- `innodb_cluster_router.yml`
- `mha.yml`
- `mha_go.yml`
- `mha_unsafe_uninstall.yml`
- `mha_go_unsafe_uninstall.yml`
- `backup_script.yml`
- `backup_script_8.4.yml`
- `restore_pitr_8.4.yml`
- `node_exporter_install.yml`
- `mysqld_exporter_install.yml`
- `router_exporter_install.yml`
- `exporter_install.yml`
- `unsafe_uninstall.yml`
- `router_unsafe_uninstall.yml`

## 编辑规则
- 主流程围绕单实例、主从、MGR、InnoDB Cluster、MHA / MHA-Go、备份与恢复、Exporter 安装与注册。
- MySQL、Percona、GreatSQL 相关术语可以按对应产品事实使用；不要把 ClickHouse 或 Prometheus 部署术语套进 MySQL 拓扑剧本。
- `libexec/dbbotctl/exporterregistrar` 是随源码仓一并发布的 Linux amd64 静态工具二进制，不要将其当作误产物删除。
- 若涉及 `mysql_ansible/exporterregistrar/` 源码变更，应同步更新：
  - `libexec/dbbotctl/exporterregistrar`
  - `mysql_ansible/exporterregistrar/README.md`
- Exporter 安装与注册要分清：
  - `node_exporter_install.yml`、`mysqld_exporter_install.yml`、`router_exporter_install.yml` 负责安装 exporter。
  - `dbbotctl exporter register` 负责 target 注册。
  - Prometheus / Grafana / Alertmanager 部署归 `monitoring_prometheus_ansible/`。
- VIP、主从切换、MHA / MHA-Go、Router HA 等能力必须保留网络接口、IP、inventory 覆盖关系和手工确认类守卫。
- 不要把生产密码、复制账号密码、监控账号密码、私钥或 token 写入 inventory 示例、文档或 `AGENTS.md`。

## 校验清单
- `cd /usr/local/dbbot/mysql_ansible/playbooks`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini single_node.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini master_slave.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini mgr.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini innodb_cluster.yml --syntax-check`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini mha_go.yml --syntax-check`
