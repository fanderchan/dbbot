[中文](./README.md)

<p align="center">
  <img src="./assets/dbbot.png" alt="dbbot logo" width="560">
</p>

# dbbot

> MySQL OPS, PRODUCTIZED

`dbbot` is a database automation delivery repository for the MySQL ecosystem. It turns deployment, replication, backup, recovery, observability, and downstream analytics onboarding into stable, repeatable, and auditable execution flows. The current repository is centered on Ansible playbooks, covers MySQL, ClickHouse, and Prometheus/Grafana scenarios, and serves as the execution base for future skills and AI agent workflows.

## Website and Docs

- Official website: https://dbbot.ai
- Online documentation: https://dbbot.ai/docs/
- GitHub repository: https://github.com/fanderchan/dbbot
- Releases: https://github.com/fanderchan/dbbot/releases
- Issues: https://github.com/fanderchan/dbbot/issues

## What Is Included

- `mysql_ansible`: Playbooks for MySQL / Percona / GreatSQL deployment, replication, backup, recovery, and common operations.
- `clickhouse_ansible`: Playbooks for ClickHouse cluster deployment, backup, recovery, and downstream analytics scenarios.
- `monitoring_prometheus_ansible`: Playbooks for Prometheus, Grafana, Alertmanager, and exporters.
- `portable-ansible-v0.5.0-py3`: A portable Ansible runtime for executing the playbooks in controlled environments.

## Project Direction

- Productized execution: solidify deterministic operations first, then reduce drift caused by environment differences and manual steps.
- Single-repo delivery: MySQL, ClickHouse, and observability capabilities are shipped on the same release cadence.
- Forward path: stabilize the execution layer now, then package high-frequency tasks as skills and connect them to an AI agent entry point.

## How To Read This Repository

`dbbot` is not a loose collection of scripts. It is a unified delivery surface for database operations:

- `mysql_ansible` handles the core OLTP delivery path.
- `clickhouse_ansible` covers downstream OLAP scenarios.
- `monitoring_prometheus_ansible` provides observability integration.
- `portable-ansible-v0.5.0-py3` supplies the shared runtime environment.

Even if you only use one capability area, deploying the full release package is recommended so the code, assets, and documentation stay aligned.

## License

Unless otherwise noted, original work in this repository is licensed under `Apache-2.0`.

Third-party components and imported assets keep their upstream licenses and are not relicensed under the repository default. See:

- [LICENSE](./LICENSE)
- [NOTICE](./NOTICE)
- [THIRD_PARTY_LICENSES.txt](./THIRD_PARTY_LICENSES.txt)
