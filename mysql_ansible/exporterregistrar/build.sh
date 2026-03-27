#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="exporterregistrar"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
RUNTIME_DIR="${SCRIPT_DIR}/../../libexec/dbbotctl"
BUILD_OUTPUT="${BUILD_DIR}/${PROJECT_NAME}"
RUNTIME_OUTPUT="${RUNTIME_DIR}/${PROJECT_NAME}"

if ! command -v go >/dev/null 2>&1; then
  echo "Error: Go is not installed." >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${RUNTIME_DIR}"

echo "Building the project..."
(
  cd "${SCRIPT_DIR}"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
    go build -trimpath -ldflags='-s -w' -o "${BUILD_OUTPUT}" .
)

cp "${BUILD_OUTPUT}" "${RUNTIME_OUTPUT}"
chmod 0755 "${RUNTIME_OUTPUT}"

echo "Build succeeded."
echo "Binary located at '${BUILD_OUTPUT}'"
echo "Runtime binary installed to '${RUNTIME_OUTPUT}'"
