#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

mkdir -p build
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o build/mysqlrouter_exporter .
