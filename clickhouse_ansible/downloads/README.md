# Downloads

`downloads/` 只用于保存本地安装包缓存，不属于公开仓库内容。

约定：

1. 不要把下载好的二进制包提交到公开仓库。
2. 公开 release 不应包含 `downloads/` 里的实际安装包。
3. 如无离线分发需求，可以保持该目录为空。

常见下载项：

```bash
clickhouse_version="23.6.1.1524"
wget "https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-${clickhouse_version}-amd64.tgz"
wget "https://packages.clickhouse.com/tgz/stable/clickhouse-server-${clickhouse_version}-amd64.tgz"
wget "https://packages.clickhouse.com/tgz/stable/clickhouse-client-${clickhouse_version}-amd64.tgz"
```

可选调试包：

```bash
wget "https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-dbg-${clickhouse_version}-amd64.tgz"
```

ZooKeeper：

```bash
zookeeper_version="3.8.4"
wget "https://archive.apache.org/dist/zookeeper/zookeeper-${zookeeper_version}/apache-zookeeper-${zookeeper_version}-bin.tar.gz"
```
