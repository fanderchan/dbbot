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
- `portable-ansible`: A portable Ansible runtime for executing the playbooks in controlled environments.
- `bin/dbbotctl`: The repository-level lifecycle CLI for local checks, support matrix queries, portable Ansible setup, upgrades, and rollbacks.

## Project Direction

- Productized execution: solidify deterministic operations first, then reduce drift caused by environment differences and manual steps.
- Single-repo delivery: MySQL, ClickHouse, and observability capabilities are shipped on the same release cadence.
- Forward path: stabilize the execution layer now, then package high-frequency tasks as skills and connect them to an AI agent entry point.

## How To Read This Repository

`dbbot` is not a loose collection of scripts. It is a unified delivery surface for database operations:

- `mysql_ansible` handles the core OLTP delivery path.
- `clickhouse_ansible` covers downstream OLAP scenarios.
- `monitoring_prometheus_ansible` provides observability integration.
- `portable-ansible` supplies the shared runtime environment.

## Portable Ansible Runtime

- The bundled runtime is currently based on `ansible-base 2.10.17`.
- It is now built with [`make_ansible_portable`](https://github.com/fanderchan/make_ansible_portable) instead of consuming the upstream `ownport/portable-ansible` package directly.
- The runtime now lives under `portable-ansible/`; the control-host bootstrap script and bundled `sshpass-x64` have moved to `libexec/dbbotctl/`.
- `dbbotctl env setup` supports registering the portable Ansible runtime on Linux and macOS control hosts. A macOS control host is intended to manage supported Linux targets; MySQL deployment targets still follow each playbook's Linux OS allowlist.
- SSH key authentication is recommended on macOS control hosts. If an inventory uses `ansible_ssh_pass`, install a macOS-compatible `sshpass` separately; the bundled `sshpass-x64` is Linux x86_64 only.
- On macOS control hosts, setup installs `passlib` into `portable-ansible/ansible/extras` so Ansible's `password_hash` filter works.

Current build command:

```bash
./build.sh \
  --python /usr/bin/python3 \
  --source ansible-base==2.10.17 \
  --without-vault \
  --without-yaml-c-extension \
  --clean-output \
  --extra-collection 'ansible.posix:==1.5.4'
```

What each flag does:

- `--python /usr/bin/python3`: selects the control-node Python used for the build and self-test.
- `--source ansible-base==2.10.17`: selects the official `ansible-base` package for the `2.10` line.
- `--without-vault`: removes the `ansible-vault` entry point plus the `cryptography` / `cffi` dependency chain to shrink the bundle; the result no longer supports vault features.
- `--without-yaml-c-extension`: drops the compiled `PyYAML` extension and falls back to the pure-Python YAML implementation.
- `--clean-output`: removes previous build artifacts with the same output name before rebuilding.
- `--extra-collection 'ansible.posix:==1.5.4'`: embeds a pinned `ansible.posix` collection into the bundle so runtime hosts do not need to install it separately.

Even if you only use one capability area, deploying the full release package is recommended so the code, assets, and documentation stay aligned.

## License

Unless otherwise noted, original work in this repository is licensed under `Apache-2.0`.

Third-party components and imported assets keep their upstream licenses and are not relicensed under the repository default. See:

- [LICENSE](./LICENSE)
- [NOTICE](./NOTICE)
- [THIRD_PARTY_LICENSES.txt](./THIRD_PARTY_LICENSES.txt)
