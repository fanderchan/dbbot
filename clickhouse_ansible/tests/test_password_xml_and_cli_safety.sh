#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clickhouse_ansible_dir="$(cd "${script_dir}/.." && pwd)"
repo_dir="$(cd "${clickhouse_ansible_dir}/.." && pwd)"
portable_ansible_home="${PORTABLE_ANSIBLE_HOME:-${repo_dir}/portable-ansible}"
render_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${render_dir}"
}
trap cleanup EXIT

DBBOT_CLICKHOUSE_PASSWORD_TEST_DIR="${render_dir}" \
  python3 "${portable_ansible_home}/ansible-playbook" \
    -i "localhost," \
    "${script_dir}/validate_password_xml_rendering.yml"

python3 - "${render_dir}" "${clickhouse_ansible_dir}" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

import yaml

render_dir = Path(sys.argv[1])
clickhouse_ansible_dir = Path(sys.argv[2])
expected_password = "Aa1$&<>\"']]>"

xml_password_paths = {
    "users.xml": "./users/default/password",
    "cluster.xml": "./remote_servers/test_cluster/shard/replica/password",
    "automation-client.xml": "./password",
    "fast-login-client.xml": "./password",
}

for filename, xpath in xml_password_paths.items():
    root = ET.parse(render_dir / filename).getroot()
    password_node = root.find(xpath)
    if password_node is None or password_node.text != expected_password:
        raise SystemExit(f"Complex password did not round-trip through {filename}")

managed_task_roots = [
    clickhouse_ansible_dir / "playbooks",
    clickhouse_ansible_dir / "roles" / "deploy_clickhouse" / "tasks",
]
for task_root in managed_task_roots:
    for task_file in task_root.rglob("*.yml"):
        if "--password" in task_file.read_text(encoding="utf-8"):
            raise SystemExit(f"Password remains in managed process arguments: {task_file}")

config_cluster_tasks = yaml.safe_load(
    (clickhouse_ansible_dir / "roles" / "deploy_clickhouse" / "tasks" / "config_cluster.yml").read_text(encoding="utf-8")
)
cluster_task = next(task for task in config_cluster_tasks if task["name"] == "Generate cluster.xml configuration (config.d)")
if cluster_task["ansible.builtin.template"]["mode"] != "0600" or cluster_task.get("no_log") is not True:
    raise SystemExit("cluster.xml must be rendered with mode 0600 and no_log enabled")

client_tasks = yaml.safe_load(
    (clickhouse_ansible_dir / "roles" / "deploy_clickhouse" / "tasks" / "config_client.yml").read_text(encoding="utf-8")
)
client_task = next(task for task in client_tasks if task["name"] == "Write protected ClickHouse automation client config")
client_template = client_task["ansible.builtin.template"]
if (
    client_template["owner"] != "root"
    or client_template["group"] != "root"
    or client_template["mode"] != "0600"
    or client_task.get("no_log") is not True
):
    raise SystemExit("Automation client credentials must be root-owned, mode 0600, and no_log protected")
PY
