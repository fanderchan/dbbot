[English](./README.en.md)

<p align="center">
  <img src="./assets/dbbot.png" alt="dbbot logo" width="560">
</p>

# dbbot

> MySQL OPS, PRODUCTIZED

`dbbot` 是一套面向 MySQL 生态的数据库自动化交付仓库，用来把部署、复制、备份、恢复、监控和下游分析接入沉淀成稳定、可重复、可审计的执行能力。当前仓库以 Ansible Playbook 为核心，覆盖 MySQL、ClickHouse 与 Prometheus/Grafana 相关场景，并作为后续 skills 与 AI agent 演进的执行底座。

## 官网与文档

- 官方网站：https://dbbot.ai
- 在线文档：https://dbbot.ai/docs/
- GitHub 仓库：https://github.com/fanderchan/dbbot
- Releases：https://github.com/fanderchan/dbbot/releases
- Issues：https://github.com/fanderchan/dbbot/issues

## 仓库包含什么

- `mysql_ansible`：MySQL / Percona / GreatSQL 部署、复制、备份、恢复与常见运维剧本。
- `clickhouse_ansible`：ClickHouse 集群部署、备份、恢复与下游分析接入相关剧本。
- `monitoring_prometheus_ansible`：Prometheus、Grafana、Alertmanager 与 exporter 相关剧本。
- `portable-ansible-v0.5.0-py3`：绿色版 Ansible 运行时，方便在目标环境中直接执行剧本。

## 项目定位

- 标准化执行：先把确定性动作固化成剧本，再降低环境差异和手工操作带来的波动。
- 单仓交付：MySQL、ClickHouse 和监控能力按同一版本节奏发布，便于追踪与验收。
- 面向下一阶段：当前先把底层执行面打磨稳定，后续再把高频动作沉淀为 skills，并接入 AI agent。

## 推荐理解方式

`dbbot` 不是一堆分散脚本的集合，而是一套围绕数据库交付与运维场景组织的统一执行面：

- `mysql_ansible` 负责核心 OLTP 交付。
- `clickhouse_ansible` 负责下游 OLAP 场景。
- `monitoring_prometheus_ansible` 负责监控接入。
- `portable-ansible-v0.5.0-py3` 提供统一运行环境。

如果你只使用其中一个子目录，也建议按完整发版包部署，避免子目录版本与文档不一致。

## License

除另有说明外，本仓原创代码采用 `Apache-2.0`。

第三方组件与导入资产保留各自上游许可证，不并入仓库默认许可证。详情见：

- [LICENSE](./LICENSE)
- [NOTICE](./NOTICE)
- [THIRD_PARTY_LICENSES.txt](./THIRD_PARTY_LICENSES.txt)
