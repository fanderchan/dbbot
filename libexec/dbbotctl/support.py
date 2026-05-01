#!/usr/bin/env python3
"""dbbotctl support matrix reader."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from itertools import zip_longest
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


STACK_FIELDS = [
    "stack_id",
    "display_name",
    "module",
    "status",
    "default_version",
    "version_rule",
    "docs",
    "notes",
]
ARCH_FIELDS = [
    "arch_id",
    "stack_id",
    "display_name",
    "topology",
    "status",
    "entrypoint",
    "inventory",
    "min_nodes",
    "default_os",
    "notes",
]
PACKAGE_FIELDS = [
    "stack_id",
    "version",
    "os_type",
    "arch_id",
    "primary_package",
    "checksum_type",
    "checksum",
    "download_url",
    "related_package_1",
    "related_package_1_checksum_type",
    "related_package_1_checksum",
    "related_package_2",
    "related_package_2_checksum_type",
    "related_package_2_checksum",
    "status",
    "notes",
]

STACK_STATUS_LABELS = {
    "supported": "supported",
    "planned": "planned",
    "evaluating": "evaluating",
    "unsupported": "unsupported",
}
RECORD_STATUS_LABELS = {
    "supported": "supported",
    "verified": "verified",
    "planned": "planned",
    "evaluating": "evaluating",
    "blocked": "blocked",
    "unsupported": "unsupported",
}
CHECKSUM_TYPES = {"sha512", "sha256", "md5", "none"}
CHECKSUM_LENGTHS = {"sha512": 128, "sha256": 64, "md5": 32}
INSTALLABLE_PACKAGE_STATUSES = {"supported", "verified"}

MYSQL_SUPPORTED_OS = {
    "rocky9",
    "bigcloud21",
    "bigcloud7",
    "bigcloud8",
    "anolis os8",
    "openeuler24",
    "openeuler20",
    "centos7",
    "centos8",
    "openeuler22",
    "redhat7",
    "redhat8",
    "kylin linux advanced serverv10",
}
CLICKHOUSE_SUPPORTED_OS = MYSQL_SUPPORTED_OS | {
    "ubuntu20",
    "ubuntu22",
    "debian10",
    "debian11",
}
RHEL7_FAMILY_OS = {"centos7", "redhat7", "bigcloud7"}
MYSQL_ARCH_VERSION_PREFIXES = {
    "mysql_mgr": {"8.0", "8.4", "9.7"},
    "mysql_innodb_cluster": {"8.4", "9.7"},
    "mysql_mha": {"5.7"},
    "mysql_mha_go": {"8.4", "9.7"},
}

DEFAULT_CPU_ARCH = "x86_64"
CHECKSUM_ABBREVIATE_PREFIX = 8
CHECKSUM_ABBREVIATE_SUFFIX = 4
PACKAGE_ABBREVIATE_MAX = 52
PACKAGE_ABBREVIATE_SUFFIX = 22

LIST_EXACT_FIELDS = ("stack", "arch", "version", "cpu-arch")
PACKAGE_EXACT_FIELDS = ("stack", "version", "os", "cpu-arch", "arch", "status")
LIST_EXACT_HELP = (
    "Use exact matching for filters. Without a value, all supported fields are exact. "
    "Fields: stack,arch,version,cpu-arch"
)
PACKAGE_EXACT_HELP = (
    "Use exact matching for filters. Without a value, all supported fields are exact. "
    "Fields: stack,version,os,cpu-arch,arch,status"
)
VERTICAL_HELP = "Use vertical output similar to MySQL \\G"

PACKAGE_TABLE_HEADERS = [
    "Stack ID",
    "Version",
    "OS",
    "CPU Arch",
    "Arch ID",
    "Primary Package",
    "Checksum",
    "Download URL",
    "Related Packages",
    "Status",
]
PACKAGE_COMPACT_BASE_HEADERS = ["Version", "OS", "Arch ID", "Primary Package", "Checksum"]
STACK_COMPACT_HEADERS = ["Stack ID", "Stack", "Arch ID", "Versions"]
STACK_FULL_HEADERS = ["Stack ID", "Stack", "Arch ID", "Versions", "CPU Arch", "Notes"]
ARCH_TABLE_HEADERS = ["Stack ID", "Stack", "Arch ID", "Architecture", "Status", "Nodes", "Default OS", "Entrypoint"]
SHOW_STACK_HEADERS = ["Stack ID", "Stack", "Module", "Status", "Default", "Version Rule", "Docs", "Notes"]
SHOW_ARCH_HEADERS = ["Arch ID", "Architecture", "Status", "Nodes", "Versions", "Default OS", "Entrypoint"]
VERIFY_PACKAGE_HEADERS = [
    "Package Path",
    "Package Role",
    "Stack ID",
    "Version",
    "OS",
    "CPU Arch",
    "Arch ID",
    "Package",
    "Exists",
    "Checksum Source",
    "Checksum Type",
    "Expected Checksum",
    "Actual Checksum",
    "Verified",
]
CHECK_TABLE_HEADERS = ["Check", "Stacks", "Architectures", "Packages"]

SUPPORT_EXAMPLES = """Examples:
  dbbotctl support list
  dbbotctl support list --full
  dbbotctl support list -G
  dbbotctl support list --stack mysql --arch innodb
  dbbotctl support show mysql
  dbbotctl support packages --stack mysql
  dbbotctl support packages --stack mysql --version 8.4.9 --os CentOS7
  dbbotctl support packages --stack mysql --version 9.7.0 --os BigCloud21 -G
  dbbotctl support packages --stack clickhouse --version 23.6.1.1524 --full
  dbbotctl support verify-package --stack mysql --version 9.7.0 --os BigCloud21 --arch mysql_innodb_cluster --packages-dir mysql_ansible/downloads --include-related
  dbbotctl support check
"""

PUBLIC_PACKAGE_FIELDS = [
    "stack_id",
    "version",
    "os_type",
    "cpu_arch",
    "arch_id",
    "primary_package",
    "related_package_1",
    "related_package_1_checksum_type",
    "related_package_1_checksum",
    "related_package_2",
    "related_package_2_checksum_type",
    "related_package_2_checksum",
    "download_url",
    "checksum_type",
    "checksum",
    "status",
    "notes",
]


class SupportDataError(Exception):
    pass


def normalize_token(value: str) -> str:
    return " ".join(value.strip().lower().split())


def natural_key(value: str) -> List[object]:
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"([0-9]+)", value)]


def version_numbers(value: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"[0-9]+", value))


def compare_versions(left: str, right: str) -> int:
    for left_part, right_part in zip_longest(version_numbers(left), version_numbers(right), fillvalue=0):
        if left_part < right_part:
            return -1
        if left_part > right_part:
            return 1
    return 0


def concrete_version_component_count(value: Optional[str]) -> int:
    if value is None:
        return 0
    if "x" in value.lower() or "{" in value:
        return 0
    return len(version_numbers(value))


def read_tsv(path: str, fields: Sequence[str]) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for lineno, raw_line in enumerate(handle, 1):
                line = raw_line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue

                values = line.split("\t")
                if len(values) != len(fields):
                    raise SupportDataError(
                        f"{path}:{lineno}: invalid field count, expected {len(fields)}, got {len(values)}"
                    )

                row = dict(zip(fields, values))
                row["_file"] = path
                row["_line"] = str(lineno)
                rows.append(row)
    except FileNotFoundError as exc:
        raise SupportDataError(f"missing support matrix file: {path}") from exc

    return rows


def load_data(root: str) -> Tuple[List[Dict[str, str]], List[Dict[str, str]], List[Dict[str, str]]]:
    support_dir = os.path.join(root, "libexec", "dbbotctl", "support")
    return (
        read_tsv(os.path.join(support_dir, "stacks.tsv"), STACK_FIELDS),
        read_tsv(os.path.join(support_dir, "architectures.tsv"), ARCH_FIELDS),
        read_tsv(os.path.join(support_dir, "packages.tsv"), PACKAGE_FIELDS),
    )


def status_label(status: str, stack_level: bool = False) -> str:
    labels = STACK_STATUS_LABELS if stack_level else RECORD_STATUS_LABELS
    return labels.get(status, status)


def print_table(headers: Sequence[str], rows: Iterable[Sequence[str]]) -> None:
    rows = list(rows)
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    fmt = "  ".join(f"{{:<{width}}}" for width in widths)
    print(fmt.format(*headers))
    for row in rows:
        print(fmt.format(*row))


def print_vertical(headers: Sequence[str], rows: Iterable[Sequence[str]]) -> None:
    for row_number, row in enumerate(rows, 1):
        print(f"*************************** {row_number}. row ***************************")
        for header, cell in zip(headers, row):
            print(f"{header}: {cell}")


def print_table_or_vertical(headers: Sequence[str], rows: Iterable[Sequence[str]], *, vertical: bool = False) -> None:
    if vertical:
        print_vertical(headers, rows)
    else:
        print_table(headers, rows)


def is_vertical(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "vertical", False))


def contains_ci(value: str, needle: Optional[str]) -> bool:
    if needle is None:
        return True
    return needle.lower() in value.lower()


def filter_value_matches(value: str, needle: Optional[str], *, exact: bool = False) -> bool:
    if needle is None:
        return True
    if exact:
        return normalize_token(value) == normalize_token(needle)
    return contains_ci(value, needle)


def filter_any_matches(values: Iterable[str], needle: Optional[str], *, exact: bool = False) -> bool:
    if needle is None:
        return True
    return any(filter_value_matches(value, needle, exact=exact) for value in values)


def parse_exact_fields(raw: Optional[str], allowed_fields: Sequence[str]) -> set:
    if raw is None:
        return set()

    allowed = set(allowed_fields)
    if raw == "all":
        return allowed

    fields = set()
    for part in re.split(r"[,，]", raw):
        field = part.strip().lower().replace("_", "-")
        if not field:
            continue
        if field == "cpu":
            field = "cpu-arch"
        elif field == "os-type":
            field = "os"
        fields.add(field)

    invalid = sorted(fields - allowed)
    if invalid:
        allowed_text = ", ".join(allowed_fields)
        raise SupportDataError(f"--exact does not support: {', '.join(invalid)}; use {allowed_text}, or all")
    return fields


def status_matches_filter(
    status: str,
    status_filter: Optional[str],
    *,
    stack_level: bool = False,
    exact: bool = False,
) -> bool:
    if status_filter is None:
        return True
    return filter_value_matches(status, status_filter, exact=exact) or filter_value_matches(
        status_label(status, stack_level=stack_level),
        status_filter,
        exact=exact,
    )


def is_installable(status: str) -> bool:
    return status in INSTALLABLE_PACKAGE_STATUSES


def selector_prefix(selector: str) -> str:
    match = re.match(r"^([0-9]+(?:\.[0-9]+)*)\.x", selector)
    if match:
        return match.group(1)
    numbers = version_numbers(selector)
    if len(numbers) >= 2:
        return f"{numbers[0]}.{numbers[1]}"
    if numbers:
        return str(numbers[0])
    return selector


def selector_matches_version(selector: str, version_filter: Optional[str], *, exact: bool = False) -> bool:
    if version_filter is None:
        return True

    version_filter = version_filter.strip()
    if not version_filter:
        return True

    if selector == version_filter:
        return True

    min_rule = re.match(r"^([0-9]+(?:\.[0-9]+)*)\.x>=(.+)$", selector)
    if min_rule:
        prefix = min_rule.group(1) + "."
        minimum = min_rule.group(2)
        if version_filter.startswith(prefix) and compare_versions(version_filter, minimum) >= 0:
            return True
        if not exact and contains_ci(selector, version_filter):
            return True
        return False

    wildcard_rule = re.match(r"^([0-9]+(?:\.[0-9]+)*)\.x$", selector)
    if wildcard_rule:
        prefix = wildcard_rule.group(1) + "."
        if version_filter.startswith(prefix):
            return True
        if not exact and contains_ci(selector, version_filter):
            return True
        return False

    if exact:
        return False
    return contains_ci(selector, version_filter)


def arch_version_allows(row: Dict[str, str], requested_arch: Optional[str]) -> bool:
    if requested_arch is None:
        return True
    allowed_prefixes = MYSQL_ARCH_VERSION_PREFIXES.get(requested_arch)
    if not allowed_prefixes:
        return True
    return selector_prefix(row["version"]) in allowed_prefixes


def version_summary(versions: Sequence[str]) -> str:
    if not versions:
        return "-"
    return ", ".join(versions)


def split_version_rule(rule: str) -> List[str]:
    return [part.strip() for part in rule.split(";") if part.strip()]


def version_range_matches(selector: str, version_filter: str, *, exact: bool = False) -> bool:
    if ".." not in selector:
        return selector_matches_version(selector, version_filter, exact=exact)

    lower, upper = [part.strip() for part in selector.split("..", 1)]
    if compare_versions(version_filter, lower) >= 0 and compare_versions(version_filter, upper) <= 0:
        return True
    if not exact and contains_ci(selector, version_filter):
        return True
    return False


def version_rule_matches_filter(selector: str, version_filter: Optional[str], *, exact: bool = False) -> bool:
    if version_filter is None:
        return True

    version_filter = version_filter.strip()
    if not version_filter:
        return True

    for part in re.split(r"\s+or\s+", selector):
        part = part.strip()
        if part and version_range_matches(part, version_filter, exact=exact):
            return True
    return False


def versions_from_stack_rule(
    stack: Dict[str, str],
    arch_id: str,
    version_filter: Optional[str] = None,
    cpu_arch_filter: Optional[str] = None,
    *,
    version_exact: bool = False,
    cpu_arch_exact: bool = False,
) -> str:
    if not filter_value_matches(DEFAULT_CPU_ARCH, cpu_arch_filter, exact=cpu_arch_exact):
        return "-"

    if stack["stack_id"] == "mysql":
        allowed_prefixes = MYSQL_ARCH_VERSION_PREFIXES.get(arch_id)
        rules = split_version_rule(stack["version_rule"])
        if allowed_prefixes:
            rules = [rule for rule in rules if selector_prefix(rule) in allowed_prefixes]
        rules = [
            rule
            for rule in rules
            if version_rule_matches_filter(rule, version_filter, exact=version_exact)
        ]
        return version_summary(rules)

    if stack["stack_id"] == "greatsql":
        rule = stack["version_rule"]
        if version_rule_matches_filter(rule, version_filter, exact=version_exact):
            return rule
        return "-"

    return "-"


def versions_for_arch(
    stack_id: str,
    arch_id: str,
    packages: Sequence[Dict[str, str]],
    version_filter: Optional[str] = None,
    cpu_arch_filter: Optional[str] = None,
    *,
    version_exact: bool = False,
    cpu_arch_exact: bool = False,
) -> str:
    versions = sorted(
        {
            row["version"]
            for row in packages
            if row["stack_id"] == stack_id
            and package_arch_matches(row["arch_id"], arch_id)
            and arch_version_allows(row, arch_id)
            and is_installable(row["status"])
            and selector_matches_version(row["version"], version_filter, exact=version_exact)
            and filter_value_matches(DEFAULT_CPU_ARCH, cpu_arch_filter, exact=cpu_arch_exact)
        },
        key=natural_key,
    )
    return version_summary(versions)


def display_versions_for_arch(
    stack: Dict[str, str],
    arch_id: str,
    packages: Sequence[Dict[str, str]],
    version_filter: Optional[str] = None,
    cpu_arch_filter: Optional[str] = None,
    *,
    version_exact: bool = False,
    cpu_arch_exact: bool = False,
) -> str:
    versions = versions_from_stack_rule(
        stack,
        arch_id,
        version_filter,
        cpu_arch_filter,
        version_exact=version_exact,
        cpu_arch_exact=cpu_arch_exact,
    )
    if versions != "-":
        return versions
    return versions_for_arch(
        stack["stack_id"],
        arch_id,
        packages,
        version_filter,
        cpu_arch_filter,
        version_exact=version_exact,
        cpu_arch_exact=cpu_arch_exact,
    )


def related_package_fields() -> List[Tuple[str, str, str]]:
    return [
        ("related_package_1", "related_package_1_checksum_type", "related_package_1_checksum"),
        ("related_package_2", "related_package_2_checksum_type", "related_package_2_checksum"),
    ]


def find_stack(stack_ref: str, stacks: Sequence[Dict[str, str]]) -> Dict[str, str]:
    needle = normalize_token(stack_ref)
    for stack in stacks:
        if normalize_token(stack["stack_id"]) == needle or normalize_token(stack["display_name"]) == needle:
            return stack
    raise SystemExit(f"unknown stack: {stack_ref}")


def package_related_list(row: Dict[str, str], *, render_version: Optional[str] = None) -> List[str]:
    related = []
    for package_field, _checksum_type_field, _checksum_field in related_package_fields():
        value = row[package_field]
        if value != "-":
            related.append(render_package_value(row, value, render_version))
    return related


def related_package_entries(row: Dict[str, str], *, render_version: Optional[str] = None) -> List[Dict[str, str]]:
    related = []
    for package_field, checksum_type_field, checksum_field in related_package_fields():
        value = row[package_field]
        if value == "-":
            continue
        related.append(
            {
                "package": render_package_value(row, value, render_version),
                "checksum_type": row[checksum_type_field],
                "checksum": row[checksum_field],
            }
        )
    return related


def package_related(
    row: Dict[str, str],
    *,
    render_version: Optional[str] = None,
    include_checksums: bool = False,
) -> str:
    if include_checksums:
        related = []
        for entry in related_package_entries(row, render_version=render_version):
            package = entry["package"]
            if entry["checksum_type"] != "none":
                package = f"{package} ({entry['checksum_type']}:{entry['checksum']})"
            related.append(package)
    else:
        related = package_related_list(row, render_version=render_version)
    return ", ".join(related) if related else "-"


def abbreviate_checksum(checksum: str) -> str:
    if len(checksum) <= CHECKSUM_ABBREVIATE_PREFIX + CHECKSUM_ABBREVIATE_SUFFIX:
        return checksum
    return f"{checksum[:CHECKSUM_ABBREVIATE_PREFIX]}...{checksum[-CHECKSUM_ABBREVIATE_SUFFIX:]}"


def abbreviate_middle(value: str, max_len: int, suffix_len: int) -> str:
    if len(value) <= max_len:
        return value
    if max_len <= suffix_len + 3:
        return value[:max_len]
    prefix_len = max_len - suffix_len - 3
    return f"{value[:prefix_len]}...{value[-suffix_len:]}"


def package_checksum(row: Dict[str, str], *, full: bool = True) -> str:
    if row["checksum_type"] == "none":
        return "none"
    checksum = row["checksum"] if full else abbreviate_checksum(row["checksum"])
    return f"{row['checksum_type']}:{checksum}"


def render_version_for_row(row: Dict[str, str], requested_version: Optional[str]) -> Optional[str]:
    if requested_version is None:
        return None
    if "{version}" not in row["primary_package"] and all(
        "{version}" not in row[field] for field, _checksum_type_field, _checksum_field in related_package_fields()
    ):
        return None
    component_count = concrete_version_component_count(requested_version)
    if row["stack_id"] == "clickhouse":
        return requested_version if component_count >= 4 else None
    return requested_version if component_count >= 3 else None


def render_package_value(row: Dict[str, str], value: str, render_version: Optional[str]) -> str:
    if render_version is None:
        return value
    return value.replace("{version}", render_version)


def package_name(row: Dict[str, str], *, full: bool = True, render_version: Optional[str] = None) -> str:
    package = render_package_value(row, row["primary_package"], render_version)
    if full:
        return package
    return abbreviate_middle(package, PACKAGE_ABBREVIATE_MAX, PACKAGE_ABBREVIATE_SUFFIX)


def package_download_url(row: Dict[str, str], *, render_version: Optional[str] = None) -> str:
    return render_package_value(row, row["download_url"], render_version)


def package_arch_matches(row_arch: str, requested_arch: str) -> bool:
    return row_arch == requested_arch or row_arch == "all"


def package_arch_filter_matches(row_arch: str, requested_arch: Optional[str], *, exact: bool = False) -> bool:
    if requested_arch is None:
        return True
    if exact:
        return package_arch_matches(row_arch, requested_arch)
    return package_arch_matches(row_arch, requested_arch) or contains_ci(row_arch, requested_arch)


def stack_supported_os(stack_id: str) -> set:
    return CLICKHOUSE_SUPPORTED_OS if stack_id == "clickhouse" else MYSQL_SUPPORTED_OS


def os_group_matches(stack_id: str, row_os: str, requested_os: Optional[str], *, exact: bool = False) -> bool:
    if requested_os is None:
        return True

    if filter_value_matches(row_os, requested_os, exact=exact):
        return True

    requested = normalize_token(requested_os)
    if row_os in {"all", "all-supported-os"}:
        return requested in stack_supported_os(stack_id)
    if row_os == "non-Rocky9":
        return requested in MYSQL_SUPPORTED_OS and requested != "rocky9"
    if row_os == "not-rhel7-family":
        return requested in MYSQL_SUPPORTED_OS and requested not in RHEL7_FAMILY_OS
    return False


def package_base_dict(row: Dict[str, str], *, requested_version: Optional[str] = None) -> Dict[str, object]:
    render_version = render_version_for_row(row, requested_version)
    version = render_version or row["version"]
    return {
        "stack_id": row["stack_id"],
        "version": version,
        "os_type": row["os_type"],
        "cpu_arch": DEFAULT_CPU_ARCH,
        "arch_id": row["arch_id"],
        "primary_package": package_name(row, render_version=render_version),
        "related_package_1": render_package_value(row, row["related_package_1"], render_version),
        "related_package_1_checksum_type": row["related_package_1_checksum_type"],
        "related_package_1_checksum": row["related_package_1_checksum"],
        "related_package_2": render_package_value(row, row["related_package_2"], render_version),
        "related_package_2_checksum_type": row["related_package_2_checksum_type"],
        "related_package_2_checksum": row["related_package_2_checksum"],
        "related_packages": package_related_list(row, render_version=render_version),
        "download_url": package_download_url(row, render_version=render_version),
    }


def package_public_dict(row: Dict[str, str], *, requested_version: Optional[str] = None) -> Dict[str, object]:
    data = package_base_dict(row, requested_version=requested_version)
    data.update(
        {
            "checksum_type": row["checksum_type"],
            "checksum": row["checksum"],
            "status": row["status"],
            "notes": row["notes"],
        }
    )
    public = {field: data[field] for field in PUBLIC_PACKAGE_FIELDS}
    public["related_packages"] = data["related_packages"]
    return public


def checksum_file(path: str, checksum_type: str) -> str:
    digest = hashlib.new(checksum_type)
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_entries_for_verification(
    row: Dict[str, str],
    package_path: str,
    *,
    requested_version: str,
    include_related: bool,
) -> List[Dict[str, object]]:
    render_version = render_version_for_row(row, requested_version)
    if "{version}" in row["primary_package"] and render_version is None:
        raise SupportDataError(f"version must be concrete enough to render package template: {requested_version}")

    entries = [
        {
            "role": "primary",
            "package": package_name(row, render_version=render_version),
            "checksum_type": row["checksum_type"],
            "checksum": row["checksum"],
        }
    ]
    if include_related:
        for idx, related in enumerate(related_package_entries(row, render_version=render_version), 1):
            entries.append(
                {
                    "role": f"related_{idx}",
                    "package": related["package"],
                    "checksum_type": related["checksum_type"],
                    "checksum": related["checksum"],
                }
            )

    for entry in entries:
        entry["package_path"] = os.path.join(package_path, str(entry["package"]))
    return entries


def verify_package_entry(row: Dict[str, str], entry: Dict[str, object], args: argparse.Namespace) -> Dict[str, object]:
    package_path = str(entry["package_path"])
    checksum_type = str(entry["checksum_type"])
    checksum_expected = str(entry["checksum"]).lower()
    result: Dict[str, object] = {
        "package_path": package_path,
        "package_role": str(entry["role"]),
        "stack_id": row["stack_id"],
        "version": args.version,
        "os_type": args.os_type,
        "cpu_arch": DEFAULT_CPU_ARCH,
        "arch_id": args.arch,
        "package": str(entry["package"]),
        "package_exists": os.path.exists(package_path),
        "checksum_source": "none",
        "checksum_type": checksum_type,
        "checksum_expected": "-",
        "checksum_actual": "-",
        "checksum_verified": False,
    }

    if not result["package_exists"]:
        return result

    if checksum_type == "none":
        return result

    checksum_actual = checksum_file(package_path, checksum_type)
    result.update(
        {
            "checksum_source": "support_matrix",
            "checksum_expected": checksum_expected,
            "checksum_actual": checksum_actual,
            "checksum_verified": checksum_actual == checksum_expected,
        }
    )
    return result


def verify_package_display_row(result: Dict[str, object]) -> List[str]:
    if result["checksum_source"] == "none" and result["package_exists"]:
        checksum_verified = "n/a"
    else:
        checksum_verified = "yes" if result["checksum_verified"] else "no"

    return [
        str(result["package_path"]),
        str(result["package_role"]),
        str(result["stack_id"]),
        str(result["version"]),
        str(result["os_type"]),
        str(result["cpu_arch"]),
        str(result["arch_id"]),
        str(result["package"]),
        "yes" if result["package_exists"] else "no",
        str(result["checksum_source"]),
        str(result["checksum_type"]),
        str(result["checksum_expected"]),
        str(result["checksum_actual"]),
        checksum_verified,
    ]


def print_verify_package_results(results: Sequence[Dict[str, object]], *, vertical: bool = False) -> None:
    rows = [verify_package_display_row(result) for result in results]
    print_table_or_vertical(VERIFY_PACKAGE_HEADERS, rows, vertical=vertical)


def resolve_package_row(packages: Sequence[Dict[str, str]], args: argparse.Namespace) -> Dict[str, str]:
    rows = [
        row
        for row in packages
        if row["stack_id"] == args.stack
        and selector_matches_version(row["version"], args.version, exact=True)
        and os_group_matches(row["stack_id"], row["os_type"], args.os_type, exact=True)
        and package_arch_matches(row["arch_id"], args.arch)
        and arch_version_allows(row, args.arch)
        and is_installable(row["status"])
    ]

    if not rows:
        request = f"stack={args.stack}, version={args.version}, os={args.os_type}, arch={args.arch}"
        raise SupportDataError(f"no installable package rule found for {request}")
    if len(rows) > 1:
        candidates = ", ".join(row["primary_package"] for row in rows)
        raise SupportDataError(f"package rule is not unique; candidates: {candidates}")
    return rows[0]


def ensure_verify_arch_exists(architectures: Sequence[Dict[str, str]], stack_id: str, arch_id: str) -> None:
    if arch_id == "all":
        return
    if any(row["stack_id"] == stack_id and row["arch_id"] == arch_id for row in architectures):
        return
    raise SupportDataError(f"unknown architecture for stack {stack_id}: {arch_id}")


def command_verify_package(
    packages: List[Dict[str, str]],
    architectures: Sequence[Dict[str, str]],
    args: argparse.Namespace,
) -> int:
    try:
        ensure_verify_arch_exists(architectures, args.stack, args.arch)
        row = resolve_package_row(packages, args)
        package_dir = os.path.abspath(args.packages_dir)
        entries = package_entries_for_verification(
            row,
            package_dir,
            requested_version=args.version,
            include_related=args.include_related,
        )
        results = [verify_package_entry(row, entry, args) for entry in entries]
    except SupportDataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.output_format == "json":
        print(json.dumps(results, ensure_ascii=False, sort_keys=True))
    elif is_vertical(args):
        print_verify_package_results(results, vertical=True)

    missing = [result for result in results if not result["package_exists"]]
    failed = [
        result
        for result in results
        if result["package_exists"] and result["checksum_source"] != "none" and not result["checksum_verified"]
    ]

    if missing:
        if args.output_format != "json":
            for result in missing:
                print(f"error: package not found: {result['package_path']}", file=sys.stderr)
        return 1

    if failed:
        if args.output_format != "json":
            for result in failed:
                print(
                    "error: "
                    f"{result['package_path']} {result['checksum_type']} checksum failed; "
                    f"expected {result['checksum_expected']}, got {result['checksum_actual']}",
                    file=sys.stderr,
                )
        return 1

    if args.output_format != "json":
        if not is_vertical(args):
            print_verify_package_results(results, vertical=False)
        print(f"PASS: {len(results)} package(s) found")
    return 0


def arch_display_row(
    row: Dict[str, str],
    *,
    stack_display_name: Optional[str] = None,
    include_stack: bool = False,
    versions: Optional[str] = None,
) -> List[str]:
    values = [
        row["arch_id"],
        row["display_name"],
        status_label(row["status"]),
        row["min_nodes"],
    ]
    if versions is not None:
        values.append(versions)
    values.extend([row["default_os"], row["entrypoint"]])
    if include_stack:
        return [row["stack_id"], stack_display_name or row["stack_id"]] + values
    return values


def command_list(
    stacks: List[Dict[str, str]],
    architectures: List[Dict[str, str]],
    packages: List[Dict[str, str]],
    args: argparse.Namespace,
) -> int:
    try:
        exact_fields = parse_exact_fields(getattr(args, "exact", None), LIST_EXACT_FIELDS)
    except SupportDataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    stack_by_id = {row["stack_id"]: row for row in stacks}
    rows = []
    full = bool(getattr(args, "full", False)) or is_vertical(args)
    for arch in architectures:
        stack = stack_by_id.get(arch["stack_id"])
        if stack is None:
            continue

        if not filter_any_matches(
            [stack["stack_id"], stack["display_name"]],
            args.stack,
            exact="stack" in exact_fields,
        ):
            continue
        if not filter_any_matches(
            [arch["arch_id"], arch["display_name"]],
            args.arch,
            exact="arch" in exact_fields,
        ):
            continue

        versions = display_versions_for_arch(
            stack,
            arch["arch_id"],
            packages,
            args.version,
            args.cpu_arch,
            version_exact="version" in exact_fields,
            cpu_arch_exact="cpu-arch" in exact_fields,
        )
        if versions == "-":
            continue
        row = [stack["stack_id"], stack["display_name"], arch["arch_id"], versions]
        if full:
            row.extend([DEFAULT_CPU_ARCH, arch["notes"]])
        rows.append(row)

    if not rows:
        print("no matching support records found")
        return 1
    headers = STACK_FULL_HEADERS if full else STACK_COMPACT_HEADERS
    print_table_or_vertical(headers, rows, vertical=is_vertical(args))
    return 0


def command_matrix(stacks: List[Dict[str, str]], architectures: List[Dict[str, str]], args: argparse.Namespace) -> int:
    stack_names = {row["stack_id"]: row["display_name"] for row in stacks}
    rows = [
        arch_display_row(
            arch,
            stack_display_name=stack_names.get(arch["stack_id"], arch["stack_id"]),
            include_stack=True,
        )
        for arch in architectures
    ]
    print_table_or_vertical(ARCH_TABLE_HEADERS, rows, vertical=is_vertical(args))
    return 0


def filtered_packages(packages: Sequence[Dict[str, str]], args: argparse.Namespace) -> List[Dict[str, str]]:
    exact_fields = parse_exact_fields(getattr(args, "exact", None), PACKAGE_EXACT_FIELDS)
    rows = list(packages)
    if args.stack:
        rows = [row for row in rows if filter_value_matches(row["stack_id"], args.stack, exact="stack" in exact_fields)]
    if args.version:
        rows = [
            row
            for row in rows
            if selector_matches_version(row["version"], args.version, exact="version" in exact_fields)
        ]
    if args.os_type:
        rows = [
            row
            for row in rows
            if os_group_matches(row["stack_id"], row["os_type"], args.os_type, exact="os" in exact_fields)
        ]
    if getattr(args, "cpu_arch", None):
        rows = [
            row
            for row in rows
            if filter_value_matches(DEFAULT_CPU_ARCH, args.cpu_arch, exact="cpu-arch" in exact_fields)
        ]
    if args.arch:
        rows = [
            row
            for row in rows
            if package_arch_filter_matches(row["arch_id"], args.arch, exact="arch" in exact_fields)
            and arch_version_allows(row, args.arch)
        ]
    if args.checksum:
        rows = [row for row in rows if row["checksum_type"] == args.checksum]
    if getattr(args, "status", None):
        rows = [row for row in rows if status_matches_filter(row["status"], args.status, exact="status" in exact_fields)]
    return rows


def package_display_rows(
    rows: Sequence[Dict[str, str]],
    *,
    full: bool = True,
    full_checksum: bool = True,
    include_stack: bool = True,
    requested_version: Optional[str] = None,
) -> List[List[str]]:
    table_rows = []
    for row in rows:
        render_version = render_version_for_row(row, requested_version)
        data = package_base_dict(row, requested_version=requested_version)
        if full:
            table_row = [
                str(data["stack_id"]),
                str(data["version"]),
                str(data["os_type"]),
                str(data["cpu_arch"]),
                str(data["arch_id"]),
                package_name(row, full=True, render_version=render_version),
                package_checksum(row, full=full_checksum),
                package_download_url(row, render_version=render_version),
                package_related(row, render_version=render_version, include_checksums=full_checksum),
                status_label(row["status"]),
            ]
        else:
            table_row = []
            if include_stack:
                table_row.append(str(data["stack_id"]))
            table_row.extend(
                [
                    str(data["version"]),
                    str(data["os_type"]),
                    str(data["arch_id"]),
                    package_name(row, full=False, render_version=render_version),
                    package_checksum(row, full=False),
                ]
            )
        table_rows.append(table_row)
    return table_rows


def package_compact_headers(*, include_stack: bool = True) -> List[str]:
    headers = []
    if include_stack:
        headers.append("Stack ID")
    headers.extend(PACKAGE_COMPACT_BASE_HEADERS)
    return headers


def print_packages(
    rows: Sequence[Dict[str, str]],
    *,
    vertical: bool = False,
    full: bool = False,
    include_stack: bool = True,
    requested_version: Optional[str] = None,
) -> None:
    table_rows = package_display_rows(
        rows,
        full=vertical or full,
        full_checksum=vertical or full,
        include_stack=include_stack,
        requested_version=requested_version,
    )
    if vertical:
        print_vertical(PACKAGE_TABLE_HEADERS, table_rows)
    elif full:
        print_table(PACKAGE_TABLE_HEADERS, table_rows)
    else:
        print_table(package_compact_headers(include_stack=include_stack), table_rows)


def command_packages(packages: List[Dict[str, str]], args: argparse.Namespace) -> int:
    try:
        rows = filtered_packages(packages, args)
    except SupportDataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not rows:
        print("no matching package records found")
        return 1
    if args.output_format == "json":
        print(
            json.dumps(
                [package_public_dict(row, requested_version=args.version) for row in rows],
                ensure_ascii=False,
                sort_keys=True,
            )
        )
    else:
        print_packages(
            rows,
            vertical=is_vertical(args),
            full=getattr(args, "full", False),
            include_stack=not bool(args.stack),
            requested_version=args.version,
        )
    return 0


def command_show(
    stacks: List[Dict[str, str]],
    architectures: List[Dict[str, str]],
    packages: List[Dict[str, str]],
    stack_ref: str,
    args: argparse.Namespace,
) -> int:
    stack = find_stack(stack_ref, stacks)
    stack_id = stack["stack_id"]
    vertical = is_vertical(args)

    if vertical:
        print_vertical(
            SHOW_STACK_HEADERS,
            [
                [
                    stack_id,
                    stack["display_name"],
                    stack["module"],
                    status_label(stack["status"], stack_level=True),
                    stack["default_version"],
                    stack["version_rule"],
                    stack["docs"],
                    stack["notes"],
                ]
            ],
        )
    else:
        print(f"Stack: {stack['display_name']} ({stack_id})")
        print(f"Module: {stack['module']}")
        print(f"Status: {status_label(stack['status'], stack_level=True)}")
        print(f"Default version: {stack['default_version']}")
        print(f"Version rule: {stack['version_rule']}")
        print(f"Docs: {stack['docs']}")
        if stack["notes"] != "-":
            print(f"Notes: {stack['notes']}")

    arch_rows = [row for row in architectures if row["stack_id"] == stack_id]
    if arch_rows:
        print("\nArchitectures:")
        print_table_or_vertical(
            SHOW_ARCH_HEADERS,
            [
                arch_display_row(
                    row,
                    versions=display_versions_for_arch(stack, row["arch_id"], packages),
                )
                for row in arch_rows
            ],
            vertical=vertical,
        )

    package_rows = [row for row in packages if row["stack_id"] == stack_id]
    if package_rows:
        print("\nPackage rules:")
        print_packages(package_rows, vertical=vertical, include_stack=False)
    return 0


def validate(
    root: str,
    stacks: List[Dict[str, str]],
    architectures: List[Dict[str, str]],
    packages: List[Dict[str, str]],
) -> List[str]:
    errors: List[str] = []
    stack_ids = set()
    arch_keys = set()
    package_keys = set()

    def validate_checksum(location: str, checksum_type: str, checksum: str, label: str) -> None:
        if checksum_type not in CHECKSUM_TYPES:
            errors.append(f"{location}: unsupported {label}_checksum_type: {checksum_type}")
            return
        if checksum_type in CHECKSUM_LENGTHS:
            checksum_len = CHECKSUM_LENGTHS[checksum_type]
            if not re.fullmatch(rf"[0-9a-fA-F]{{{checksum_len}}}", checksum):
                errors.append(f"{location}: invalid {checksum_type} checksum for {label}: {checksum}")
        elif checksum_type == "none" and checksum != "-":
            errors.append(f"{location}: {label} checksum must be - when checksum_type=none")

    for row in stacks:
        location = f"{row['_file']}:{row['_line']}"
        stack_id = row["stack_id"]
        if stack_id in stack_ids:
            errors.append(f"{location}: duplicate stack_id: {stack_id}")
        stack_ids.add(stack_id)

        if row["status"] not in STACK_STATUS_LABELS:
            errors.append(f"{location}: unsupported stack status: {row['status']}")
        if row["docs"] != "-" and not os.path.exists(os.path.join(root, row["docs"])):
            errors.append(f"{location}: docs path does not exist: {row['docs']}")
        if not row["default_version"]:
            errors.append(f"{location}: default_version must not be empty")
        if not row["version_rule"]:
            errors.append(f"{location}: version_rule must not be empty")

    for row in architectures:
        location = f"{row['_file']}:{row['_line']}"
        key = (row["stack_id"], row["arch_id"])
        if key in arch_keys:
            errors.append(f"{location}: duplicate architecture record: {row['stack_id']}/{row['arch_id']}")
        arch_keys.add(key)

        if row["stack_id"] not in stack_ids:
            errors.append(f"{location}: undefined stack_id: {row['stack_id']}")
        if row["status"] not in RECORD_STATUS_LABELS:
            errors.append(f"{location}: unsupported architecture status: {row['status']}")
        if not row["min_nodes"].isdigit():
            errors.append(f"{location}: min_nodes must be numeric: {row['min_nodes']}")

        for field in ("entrypoint", "inventory"):
            if row[field] != "-" and not os.path.exists(os.path.join(root, row[field])):
                errors.append(f"{location}: {field} path does not exist: {row[field]}")

    for row in packages:
        location = f"{row['_file']}:{row['_line']}"
        key = (row["stack_id"], row["version"], row["os_type"], row["arch_id"], row["primary_package"])
        if key in package_keys:
            errors.append(f"{location}: duplicate package record: {'/'.join(key)}")
        package_keys.add(key)

        if row["stack_id"] not in stack_ids:
            errors.append(f"{location}: undefined stack_id: {row['stack_id']}")
        if row["arch_id"] != "all" and (row["stack_id"], row["arch_id"]) not in arch_keys:
            errors.append(f"{location}: undefined architecture: {row['stack_id']}/{row['arch_id']}")
        if row["status"] not in RECORD_STATUS_LABELS:
            errors.append(f"{location}: unsupported package status: {row['status']}")
        if row["primary_package"] in {"", "-"}:
            errors.append(f"{location}: primary_package must not be empty")
        if row["download_url"] != "-" and not row["download_url"].startswith("https://"):
            errors.append(f"{location}: download_url must be - or an https URL: {row['download_url']}")
        validate_checksum(location, row["checksum_type"], row["checksum"], "primary_package")
        for package_field, checksum_type_field, checksum_field in related_package_fields():
            if row[package_field] == "-":
                if row[checksum_type_field] != "none" or row[checksum_field] != "-":
                    errors.append(f"{location}: {package_field} checksum must be none/- when package is -")
                continue
            validate_checksum(location, row[checksum_type_field], row[checksum_field], package_field)

    return errors


def command_check(
    root: str,
    stacks: List[Dict[str, str]],
    architectures: List[Dict[str, str]],
    packages: List[Dict[str, str]],
    args: argparse.Namespace,
) -> int:
    errors = validate(root, stacks, architectures, packages)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    if is_vertical(args):
        print_vertical(CHECK_TABLE_HEADERS, [["PASS", str(len(stacks)), str(len(architectures)), str(len(packages))]])
    else:
        print(
            "PASS: support matrix data is valid; "
            f"stacks={len(stacks)}, architectures={len(architectures)}, packages={len(packages)}"
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dbbotctl support",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=SUPPORT_EXAMPLES,
    )
    vertical_parent = argparse.ArgumentParser(add_help=False)
    vertical_parent.add_argument(
        "-G",
        "--vertical",
        action="store_true",
        default=argparse.SUPPRESS,
        help=VERTICAL_HELP,
    )
    subparsers = parser.add_subparsers(dest="command")

    list_parser = subparsers.add_parser("list", parents=[vertical_parent], help="List supported database stacks")
    list_parser.add_argument("--stack", help="Filter by stack ID or name, partial match by default")
    list_parser.add_argument("--arch", help="Filter by architecture ID or name, partial match by default")
    list_parser.add_argument("--version", help="Filter by version or version rule")
    list_parser.add_argument("--cpu-arch", help="Filter by CPU architecture, currently x86_64")
    list_parser.add_argument("--exact", nargs="?", const="all", help=LIST_EXACT_HELP)
    list_parser.add_argument("--full", action="store_true", help="Show CPU architecture and notes")

    subparsers.add_parser("matrix", parents=[vertical_parent], help="List stack and deployment architecture matrix")

    show_parser = subparsers.add_parser("show", parents=[vertical_parent], help="Show one stack in detail")
    show_parser.add_argument("stack")

    packages_parser = subparsers.add_parser("packages", parents=[vertical_parent], help="List version and package rules")
    packages_parser.add_argument("--stack")
    packages_parser.add_argument("--version")
    packages_parser.add_argument("--os", dest="os_type")
    packages_parser.add_argument("--cpu-arch", help="Filter by CPU architecture, currently x86_64")
    packages_parser.add_argument("--arch")
    packages_parser.add_argument("--checksum", choices=sorted(CHECKSUM_TYPES))
    packages_parser.add_argument("--status", help="Filter by status, such as supported or verified")
    packages_parser.add_argument("--exact", nargs="?", const="all", help=PACKAGE_EXACT_HELP)
    packages_parser.add_argument(
        "--full",
        action="store_true",
        help="Show CPU architecture, full package names, download URLs, related packages, and status",
    )
    packages_parser.add_argument("--format", dest="output_format", choices=["text", "json"], default="text")

    verify_parser = subparsers.add_parser("verify-package", parents=[vertical_parent], help="Verify package existence and checksum")
    verify_parser.add_argument("--stack", required=True)
    verify_parser.add_argument("--version", required=True)
    verify_parser.add_argument("--os", dest="os_type", required=True)
    verify_parser.add_argument("--arch", required=True)
    verify_parser.add_argument("--packages-dir", required=True)
    verify_parser.add_argument(
        "--include-related",
        action="store_true",
        help="Also verify related packages such as MySQL Shell, Router, or ClickHouse server/client",
    )
    verify_parser.add_argument("--format", dest="output_format", choices=["text", "json"], default="text")

    subparsers.add_parser("check", parents=[vertical_parent], help="Validate support matrix data")
    return parser


def main(argv: Sequence[str]) -> int:
    if len(argv) < 2:
        print("usage: support.py <dbbot_root> <subcommand> [args]", file=sys.stderr)
        return 2

    root = os.path.abspath(argv[0])
    parser = build_parser()
    args = parser.parse_args(argv[1:])

    if args.command is None:
        parser.print_help()
        return 0

    try:
        stacks, architectures, packages = load_data(root)
    except SupportDataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.command == "list":
        return command_list(stacks, architectures, packages, args)
    if args.command == "matrix":
        return command_matrix(stacks, architectures, args)
    if args.command == "show":
        return command_show(stacks, architectures, packages, args.stack, args)
    if args.command == "packages":
        return command_packages(packages, args)
    if args.command == "verify-package":
        return command_verify_package(packages, architectures, args)
    if args.command == "check":
        return command_check(root, stacks, architectures, packages, args)

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
