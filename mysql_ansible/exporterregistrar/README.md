# exporterregistrar

`exporterregistrar` 是 `dbbot` 随仓发布的辅助工具，用于把 `node_exporter` 和 `mysqld_exporter` 的目标地址写入 Prometheus `file_sd` 目标文件，避免手工编辑 YAML。

## 仓库内二进制位置

- 发布位置：`/usr/local/dbops/mysql_ansible/playbooks/exporterregistrar`
- 源码位置：`/usr/local/dbops/mysql_ansible/exporterregistrar`

## 适用范围

- 随仓提供的二进制面向 `Linux x86_64 (amd64)` 控制节点。
- 构建参数固定为：
  - `CGO_ENABLED=0`
  - `GOOS=linux`
  - `GOARCH=amd64`
  - `GOAMD64=v1`
- 这意味着它是 Go 静态二进制，不依赖目标机 glibc 版本，适合常见 Red Hat 系控制节点直接运行。

## 何时需要手动编译

出现以下情况时，建议手动重编译：

- 你修改了 `exporterregistrar` 源码
- 你的控制节点不是 `Linux amd64`
- 你的环境对 CPU 指令集、内核或安全基线有额外约束
- 下载源码仓后执行二进制失败

## 手动编译

在源码目录执行：

```bash
cd /usr/local/dbops/mysql_ansible/exporterregistrar
sh build.sh
```

构建成功后会同时生成：

- `build/exporterregistrar`
- `../playbooks/exporterregistrar`

如需自定义目标平台，可自行调整 `build.sh` 中的 `GOOS`、`GOARCH`、`GOAMD64` 参数后重新编译。
