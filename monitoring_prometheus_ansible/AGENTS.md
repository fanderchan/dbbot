# Monitoring 模块说明

本文件只承载 `monitoring_prometheus_ansible/` 子树相关的约定。跨模块通用规则（语言、绿色版 Ansible、发版、文档同步等）以仓库根目录 `AGENTS.md` 为准。

## /init 入口文件
- `monitoring_prometheus_ansible/playbooks/ansible.cfg`
- `monitoring_prometheus_ansible/playbooks/common_config.yml`
- `monitoring_prometheus_ansible/playbooks/monitoring_prometheus_deployment.yml`
- `monitoring_prometheus_ansible/inventory/hosts.ini`

## 默认实验环境假设
- 默认 inventory 位于 `monitoring_prometheus_ansible/inventory/hosts.ini`。
- 默认安装包目录为 `monitoring_prometheus_ansible/downloads/`。
- 默认变量入口位于：
  - `monitoring_prometheus_ansible/playbooks/default/common_config.yml`
  - `monitoring_prometheus_ansible/playbooks/default/var_monitoring_prometheus_deployment.yml`
  - `monitoring_prometheus_ansible/playbooks/vars/var_monitoring_prometheus_deployment.yml`

## 公开入口
- `monitoring_prometheus_deployment.yml`

## 编辑规则
- 监控部署与 exporter 注册要分清：
  - 本模块负责 Prometheus / Grafana / Alertmanager 部署。
  - MySQL exporter 安装入口位于 `mysql_ansible/`。
  - target 注册与验收通过 `dbbotctl exporter register` 和 Prometheus Targets 页面完成。
- Grafana dashboard、Prometheus scrape config、Alertmanager 配置变更必须同步核对中英文文档。
- 不要把 SMTP 密码、Webhook token、Grafana 管理员密码、私钥或其他凭据写入 inventory 示例、文档或 `AGENTS.md`。

## 校验清单
- `cd /usr/local/dbbot/monitoring_prometheus_ansible/playbooks`
- `python3 ../../portable-ansible/ansible-playbook -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check`
