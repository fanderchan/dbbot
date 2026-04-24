# dbbot 开发指引

## 说明
- 本文件定义 `dbbot` 仓库的协作规范，主要面向 AI 编码助手（Claude Code / Cursor / Codex 等），也适用于人类贡献者。
- 适用范围覆盖本仓所有子目录，包括 `mysql_ansible/`、`clickhouse_ansible/`、`monitoring_prometheus_ansible/`、`portable-ansible/`。
- 当同仓内不存在更近层级的 `AGENTS.md` 时，默认以本文件为基线。

## 仓库结构
- `mysql_ansible/`：MySQL 生态部署、备份、恢复、运维 Playbook。
- `clickhouse_ansible/`：ClickHouse 集群、NFS、备份、恢复、校验、清理 Playbook。
- `monitoring_prometheus_ansible/`：Prometheus / Alertmanager / Grafana 部署 Playbook。
- `portable-ansible/`：绿色版 Ansible 运行时。

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
  - `PORTABLE_ANSIBLE_HOME=/usr/local/dbbot/portable-ansible`
- 文档面向用户时：
  - 可写 `ansible-playbook`
  - 前提是已执行 `dbbotctl env setup` 或 `sh /usr/local/dbbot/libexec/dbbotctl/setup_portable_ansible.sh`，并 `source ~/.bashrc`
- 自动化、脚本、非交互执行时：
  - 优先使用显式路径，不依赖 alias：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook ...`
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible ...`
- 版本自检：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook --version`
- 在最小化 IaaS 测试环境中：
  - 优先保持客机为“只保证能正常 yum”的最小状态，不预装额外依赖包来掩盖 `dbbot` 缺口
  - 将仓库拷贝到控制节点后，先执行 `sh /usr/local/dbbot/libexec/dbbotctl/setup_portable_ansible.sh` 并 `source ~/.bashrc`
  - 若后续仍缺少依赖，应作为 `dbbot` 待补能力反馈，而不是先在客机上手工 `yum install`

## 入口约定
- 只有 `playbooks/` 下顶层入口 playbook 允许直接执行。
- `playbooks/tasks/`、`playbooks/pre_tasks/`、`roles/*/tasks/` 下文件默认视为内部复用片段，不单独作为入口。
- 下列"公开入口"清单只收录拓扑、备份恢复、监控部署、卸载等核心运维入口；辅助工具安装入口（如 `install_mysqlshell.yml`、`install_xtrabackup.yml`、`install_sysbench.yml`）不纳入清单，但仍允许直接执行。
- 新增核心入口时需同步更新本清单；新增辅助工具入口不必登记。

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
- `node_exporter_install.yml`
- `mysqld_exporter_install.yml`
- `router_exporter_install.yml`
- `exporter_install.yml`（兼容旧入口，等价于 `mysqld_exporter_install.yml`）
- `unsafe_uninstall.yml`
- `router_unsafe_uninstall.yml`

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
- 代码产物语言：
  - 所有代码、代码内注释、日志输出、commit message、Ansible task `name`、`fail` / `debug` 的 `msg`、模板 `.j2` 注释、shell / Go / Python 源码注释，**必须使用英文**。
  - 不受此限制：本文件（`AGENTS.md`）、文档站 `content/zh-cn/` 目录、issue / PR 讨论、与用户的对话。
  - 目的：便于国际贡献者 review、grep 定位、跨时区排错。
- 优先采用可幂等、可回放的 Ansible 方案。只有当现有 `ansible.builtin.*` 或社区 collection 模块确实无法完成时才写 `shell:` / `command:`；一旦写了，必须同时提供 `changed_when` 和合理的 `failed_when`。
- 统一使用 Ansible FQCN 模块（`ansible.builtin.*`）。
- 变量名使用 `lower_snake_case`。
- Role 命名约定（存量不追溯，新增遵守）：
  - `install_<software>`：仅安装单个软件包 / 二进制（例：`install_xtrabackup`）
  - `setup_<component>`：安装并配置单个组件（例：`setup_mysqlshell`）
  - `make_<topology>`：编排多节点、多组件拓扑（例：`make_mgr`、`make_innodb_cluster`）
  - 其他裸名词 role（`mysql_server`、`backup_script` 等）属历史命名，保留但不扩展
- 拓扑、账号、端口、路径优先放在 inventory 或 `vars/*.yml`，避免写死在 task / template 中。
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
  - 默认密码、默认用户名 / 组
  - 数据目录、socket 路径、systemd unit 名
  - 分片 / 副本逻辑
  - 备份 / 恢复对象范围
- 行为变化必须同步更新：
  - 对应 `vars/*.yml`
  - 示例 inventory
  - 相关文档
- 公开文档位于独立的 Hugo 站点仓（本机常见路径 `/usr/local/dbbot_web`）：
  - 中文文档：`content/zh-cn/docs/`
  - 英文文档：`content/en/docs/`
  - 中英双语必须同步更新；英文是国际贡献者的唯一入口，不能缺失

## Release Policy

### Required Release Note File
- 每个 release tag 或 pre-release tag 在推送前必须存在：
  - `.github/release-notes/<tag>.md`
- 若文件缺失，对应 release workflow 必须失败。

### Release Note Language
- 所有 release note 必须仅使用英文。

### Content Source Policy
- GitHub auto-generated release notes 不能作为最终 release body。
- release workflow 必须：
  1. 发布预先写好的 release note 文件内容。
  2. 在其后追加 compare link。

### Beta / Pre-release Policy
- Beta release 不要求固定 section 布局。
- 可以使用自由格式的英文总结。
- 但 comparison baseline 仍必须是上一个 official release。
- Beta release 绝不能与上一个 beta release 做比较。

### Official Release Policy
- Official release note 只能使用以下 section，并且顺序必须严格一致：
  - `## [Note]`
  - `## [Add]`
  - `## [Change]`
  - `## [Fix]`
  - `## [Remove]`
- 空 section 可以省略，但顺序不能变化。
- summary baseline 必须是上一个 official release。
- 若不存在上一个 official release，则将当前 official release 视为第一个 official release，并使用整个仓库历史 / 当前代码库作为比较范围。
- Official release 绝不能以 beta release 作为 comparison baseline。

### Sync Policy
- 若某个 tag 已经发布，而 `.github/release-notes/<tag>.md` 之后被更新，对应 sync workflow 必须自动更新已有 GitHub Release body。

### Source of Truth
- `.github/release-notes/<tag>.md` 是 release body 的唯一真相源。
- GitHub Release UI 中的手工编辑不能覆盖受管内容。

## 校验清单
- 交付前至少做语法检查：

### MySQL
- `cd /usr/local/dbbot/mysql_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible/ansible-playbook -i ../inventory/hosts.ini single_node.yml --syntax-check`

### ClickHouse
- `cd /usr/local/dbbot/clickhouse_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible/ansible-playbook -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check`
- `python3 /usr/local/dbbot/portable-ansible/ansible-playbook -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check`

### Monitoring
- `cd /usr/local/dbbot/monitoring_prometheus_ansible/playbooks`
- `python3 /usr/local/dbbot/portable-ansible/ansible-playbook -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check`

- 若改动了 Ansible 代码，建议本地再跑一次 lint：
  - `sh /usr/local/dbbot/mysql_ansible/lint_all_yml_files.sh`（或对应子项目同名脚本）
- 若改动了 Hugo 文档站内容，还应执行：
  - `cd /usr/local/dbbot_web && npm run build`

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
- `libexec/dbbotctl/exporterregistrar` 是随源码仓一并发布的 Linux amd64 静态工具二进制，不要将其当作“孤立误产物”删除。
- 若涉及 `mysql_ansible/exporterregistrar/` 源码变更，应同步更新：
  - `libexec/dbbotctl/exporterregistrar`
  - `mysql_ansible/exporterregistrar/README.md`
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
