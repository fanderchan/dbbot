# Contributing to dbbot

Thanks for your interest in `dbbot`.

`dbbot` is maintained primarily through maintainer-led work on `main`. Issues and discussions are the preferred way to propose changes, report bugs, and align on scope before code is written.

## Before You Open an Issue

- Search existing issues and discussions first.
- Use Discussions for usage questions, ideas, and open-ended design topics.
- Use Issues for actionable bugs, feature requests, and documentation corrections.
- Redact passwords, tokens, SSH keys, private inventories, internal hostnames, and other sensitive data.

## What Makes a Good Bug Report

For operational automation repositories, vague bug reports cost a lot of time. A good report includes:

- the affected area: MySQL, ClickHouse, Monitoring, Portable Ansible, or Website / Docs
- the exact entry playbook path that was executed
- the `dbbot` version and target OS / distribution version
- the target database version when relevant
- the exact command that was run
- a redacted inventory excerpt
- the failing task or error output
- expected behavior and actual behavior

## Pull Request Policy

External pull requests are welcome, but they are reviewed selectively.

- Small, focused fixes are much more likely to be accepted than large surprise changes.
- Please open an issue or discussion first for anything non-trivial.
- PRs that change sensitive defaults or expand scope without prior alignment may be closed.
- Maintainers may continue to commit directly to `main`.

## Repo-Specific Expectations

- Use top-level playbooks under `*/playbooks/` as public entry points.
- Treat `playbooks/tasks/`, `playbooks/pre_tasks/`, and `roles/*/tasks/` as internal building blocks.
- Prefer idempotent Ansible changes over one-off shell logic.
- Use FQCN modules such as `ansible.builtin.*`.
- Keep variables in `lower_snake_case`.
- Keep topology, account, port, and path choices in inventory or `vars/*.yml` where possible.
- Do not silently change sensitive defaults such as ports, default passwords, replication behavior, sharding behavior, or backup / restore scope.
- If behavior changes, update related vars, sample inventory, and documentation together.

## Validation

Run the relevant syntax checks before sending a PR.

### MySQL

```bash
cd /usr/local/dbbot/mysql_ansible/playbooks
python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.ini single_node.yml --syntax-check
```

### ClickHouse

```bash
cd /usr/local/dbbot/clickhouse_ansible/playbooks
python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.deploy.ini deploy_cluster.yml --syntax-check
python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.restore.ini restore_cluster.yml --syntax-check
```

### Monitoring

```bash
cd /usr/local/dbbot/monitoring_prometheus_ansible/playbooks
python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook -i ../inventory/hosts.ini monitoring_prometheus_deployment.yml --syntax-check
```
