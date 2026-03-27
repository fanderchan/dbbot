# dbbot repository instructions

This repository is a database delivery and operations automation monorepo built around Ansible playbooks.

## Structure

- Public entry points are only the top-level playbooks under each `*/playbooks/` directory.
- Files under `playbooks/tasks/`, `playbooks/pre_tasks/`, and `roles/*/tasks/` are internal reuse fragments, not standalone entry points.
- Main subprojects are `mysql_ansible`, `clickhouse_ansible`, `monitoring_prometheus_ansible`, and `portable-ansible-v0.5.0-py3`.

## Implementation Rules

- Prefer idempotent Ansible changes over one-off shell scripts.
- Use Ansible FQCN modules such as `ansible.builtin.*`.
- Keep variable names in `lower_snake_case`.
- Keep topology, account, port, and path values in inventory or `vars/*.yml` instead of hardcoding them in tasks or templates.
- Do not silently change sensitive defaults such as ports, default passwords, replication or sharding behavior, or backup / restore scope.
- Preserve confirmation and guard rails for uninstall, cleanup, restore, overwrite, and other risky operations.

## Execution

- For automation and non-interactive commands, prefer explicit portable Ansible paths:
  - `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible-playbook ...`
  - `python3 /usr/local/dbbot/portable-ansible-v0.5.0-py3/ansible ...`
- Do not assume aliases or shell profile setup.

## Validation

- If behavior changes, update related vars, sample inventory, and docs together.
- Run the relevant `ansible-playbook --syntax-check` command for the touched subproject.
- Do not remove `libexec/dbbotctl/exporterregistrar`; it is a shipped binary artifact.
