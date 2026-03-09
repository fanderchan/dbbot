#!/bin/bash

# 项目名称变量
PROJECT_NAME="exporterregistrar"

# 检查 Go 是否安装
if ! [ -x "$(command -v go)" ]; then
  echo "Error: Go is not installed." >&2
  exit 1
fi

# 检查 build 目录是否存在，如果不存在则创建
if [ ! -d "build" ]; then
  echo "Creating 'build' directory..."
  mkdir build
fi

# 执行 go build 命令
# 约束到 linux/amd64 + GOAMD64=v1，并关闭 CGO，
# 以获得更保守的 x86_64 兼容性和静态链接结果。
echo "Building the project..."
if CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 go build -trimpath -ldflags='-s -w' -o build/${PROJECT_NAME}; then
    cp build/${PROJECT_NAME} ../playbooks/${PROJECT_NAME}
    echo "Build succeeded. Binary located at 'build/${PROJECT_NAME}'"
else
    echo "Build failed."
    exit 1
fi
