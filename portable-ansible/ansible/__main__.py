#!/usr/bin/env python3
#
# Copyright 2026 Fander Chan
# SPDX-License-Identifier: Apache-2.0

import importlib
import os
import shutil
import sys
import traceback
from pathlib import Path

ENTRYPOINTS = {
    "ansible": ("ansible.cli.adhoc", "main"),
    "ansible-config": ("ansible.cli.config", "main"),
    "ansible-connection": ("ansible.cli.scripts.ansible_connection_cli_stub", "main"),
    "ansible-console": ("ansible.cli.console", "main"),
    "ansible-doc": ("ansible.cli.doc", "main"),
    "ansible-galaxy": ("ansible.cli.galaxy", "main"),
    "ansible-inventory": ("ansible.cli.inventory", "main"),
    "ansible-playbook": ("ansible.cli.playbook", "main"),
    "ansible-pull": ("ansible.cli.pull", "main"),
    "ansible-vault": ("ansible.cli.vault", "main"),
}

LEGACY_CLI_CLASSES = {
    "ansible": ("ansible.cli.adhoc", "AdHocCLI"),
    "ansible-config": ("ansible.cli.config", "ConfigCLI"),
    "ansible-console": ("ansible.cli.console", "ConsoleCLI"),
    "ansible-doc": ("ansible.cli.doc", "DocCLI"),
    "ansible-galaxy": ("ansible.cli.galaxy", "GalaxyCLI"),
    "ansible-inventory": ("ansible.cli.inventory", "InventoryCLI"),
    "ansible-playbook": ("ansible.cli.playbook", "PlaybookCLI"),
    "ansible-pull": ("ansible.cli.pull", "PullCLI"),
    "ansible-vault": ("ansible.cli.vault", "VaultCLI"),
}

PATH_SUFFIX_BLOCKLIST = {
    "site-packages",
    "dist-packages",
    "lib-old",
    "lib-tk",
    "gtk-2.0",
}
COLLECTIONS_ENV_VARS = ("ANSIBLE_COLLECTIONS_PATH", "ANSIBLE_COLLECTIONS_PATHS")


class LauncherError(RuntimeError):
    pass


def _bundle_root() -> Path:
    return Path(__file__).resolve().parent


def _normalized_command_name(raw_name: str) -> str:
    if raw_name in ENTRYPOINTS:
        return raw_name

    parts = raw_name.split("-")
    if len(parts) > 1 and parts[-1] and parts[-1][0].isdigit():
        candidate = "-".join(parts[:-1])
        if candidate in ENTRYPOINTS:
            return candidate

    return raw_name


def _filtered_sys_path(bundle_root):
    bundle_text = os.path.normpath(str(bundle_root))
    extras_text = os.path.normpath(str(bundle_root / "extras"))
    filtered = []

    for raw_path in sys.path:
        if not raw_path:
            continue

        normalized = os.path.normpath(raw_path)
        if normalized in {bundle_text, extras_text}:
            continue

        if os.path.basename(normalized) in PATH_SUFFIX_BLOCKLIST:
            continue

        filtered.append(raw_path)

    return [extras_text, bundle_text, *filtered]


def _activate_bundle_imports(bundle_root: Path) -> None:
    sys.path[:] = _filtered_sys_path(bundle_root)


def _prepend_env_path(variable_name: str, preferred_path: str) -> None:
    normalized_preferred = os.path.normpath(preferred_path)
    entries = [preferred_path]
    for raw_entry in os.environ.get(variable_name, "").split(os.pathsep):
        if not raw_entry:
            continue
        if os.path.normpath(raw_entry) == normalized_preferred:
            continue
        entries.append(raw_entry)
    os.environ[variable_name] = os.pathsep.join(entries)


def _activate_bundle_collection_path(bundle_root: Path) -> None:
    collections_text = os.path.normpath(str(bundle_root.parent / "collections"))
    for variable_name in COLLECTIONS_ENV_VARS:
        _prepend_env_path(variable_name, collections_text)


def _load_attribute(module_name: str, attribute_name: str):
    module = importlib.import_module(module_name)
    return getattr(module, attribute_name)


def _coerce_argv():
    try:
        from ansible.module_utils._text import to_text

        return [to_text(arg, errors="surrogate_or_strict") for arg in sys.argv]
    except Exception:
        return list(sys.argv)


def _run_legacy_cli(command_name: str) -> int:
    module_name, class_name = LEGACY_CLI_CLASSES[command_name]
    cli_class = _load_attribute(module_name, class_name)
    cli = cli_class(_coerce_argv())

    parse = getattr(cli, "parse", None)
    if callable(parse):
        parse()

    result = cli.run()
    return 0 if result is None else int(result)


def _run_command(command_name: str) -> int:
    if command_name not in ENTRYPOINTS:
        raise LauncherError(f"Unknown Ansible alias: {command_name}")

    module_name, attribute_name = ENTRYPOINTS[command_name]
    try:
        callable_entrypoint = _load_attribute(module_name, attribute_name)
    except (AttributeError, ImportError, ModuleNotFoundError):
        if command_name not in LEGACY_CLI_CLASSES:
            raise
        return _run_legacy_cli(command_name)

    result = callable_entrypoint()
    return 0 if result is None else int(result)


def _cleanup_ansible_tempdir() -> None:
    try:
        constants = importlib.import_module("ansible.constants")
        temp_dir = getattr(constants, "DEFAULT_LOCAL_TMP", None)
        if temp_dir:
            shutil.rmtree(temp_dir, ignore_errors=True)
    except Exception:
        pass


def main() -> int:
    bundle_root = _bundle_root()
    _activate_bundle_imports(bundle_root)
    _activate_bundle_collection_path(bundle_root)
    command_name = _normalized_command_name(os.path.basename(sys.argv[0]))

    try:
        return _run_command(command_name)
    except KeyboardInterrupt:
        print("User interrupted execution", file=sys.stderr)
        return 99
    except Exception as exc:
        print(f"Unexpected exception: {exc}", file=sys.stderr)
        print(traceback.format_exc(), file=sys.stderr)
        return 250
    finally:
        _cleanup_ansible_tempdir()


if __name__ == "__main__":
    sys.exit(main())
