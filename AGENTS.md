# dbbot 协作指引

本文件只承载跨模块通用约定。涉及具体子项目的入口文件、默认实验环境、公开入口、syntax-check 命令和模块特有编辑规则，统一拆到各模块根目录的 `AGENTS.md`：

- `mysql_ansible/AGENTS.md`
- `clickhouse_ansible/AGENTS.md`
- `monitoring_prometheus_ansible/AGENTS.md`

工作进入某个子模块时，请优先读对应模块的 `AGENTS.md`，再回看本文件确认跨模块规则。

## 仓库定位
- `mysql_ansible/`：MySQL / Percona / GreatSQL 部署、复制、备份、恢复、监控接入与运维 Playbook。
- `clickhouse_ansible/`：ClickHouse 集群、NFS、备份、恢复、校验与清理 Playbook。
- `monitoring_prometheus_ansible/`：Prometheus / Alertmanager / Grafana 部署 Playbook。
- `portable-ansible/`：绿色版 Ansible 运行时。
- `bin/dbbotctl` 与 `libexec/dbbotctl/`：根仓级生命周期 CLI 与配套工具。

## /init 基线
- 首先必须读取仓库根级三件：
  - `README.md`
  - `VERSION`
  - `AGENTS.md`（本文件）
- 然后按任务所属子项目读取对应模块的 `AGENTS.md`，再按其中给出的入口文件清单展开。

## 绿色版 Ansible（统一约定）
- 根仓默认使用绿色版 Ansible：
  - `PORTABLE_ANSIBLE_HOME=/usr/local/dbbot/portable-ansible`
- 文档面向用户时：
  - 可写 `ansible-playbook`
  - 前提是已执行 `dbbotctl env setup` 或 `sh /usr/local/dbbot/libexec/dbbotctl/setup_portable_ansible.sh`，并 `source ~/.bashrc`
- 自动化、脚本、非交互执行时：
  - 优先使用显式路径，不依赖 alias：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook ...`
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible ...`
- 版本自检：
  - `python3 ${PORTABLE_ANSIBLE_HOME}/ansible-playbook --version`
- 在最小化 IaaS 测试环境中：
  - 优先保持客机为“只保证能正常 yum”的最小状态，不预装额外依赖包来掩盖 `dbbot` 缺口。
  - 将仓库拷贝到控制节点后，先执行 `sh /usr/local/dbbot/libexec/dbbotctl/setup_portable_ansible.sh` 并 `source ~/.bashrc`。
  - 若依赖仍缺失，应作为 `dbbot` 待补能力反馈，不先在客机上手工 `yum install`。

## 语言与文档
- 所有代码产物必须使用英文，包括代码内注释、日志输出、commit message、Ansible task `name`、`fail` / `debug` 的 `msg`、模板 `.j2` 注释、shell / Go / Python 源码注释。
- 不受英文限制的内容：
  - 本文件和各模块 `AGENTS.md`
  - 文档站 `content/zh-cn/` 目录
  - issue / PR 讨论
  - 与用户的对话
- 公开文档位于独立 Hugo 站点仓（本机常见路径 `/usr/local/dbbot_web`）：
  - 中文文档：`content/zh-cn/docs/`
  - 英文文档：`content/en/docs/`
- 公开文档必须中英双语同步更新；英文文档是国际贡献者入口，不能缺失。
- MySQL 文档示例版本优先使用对应系列的最新可用小版本；文档示例版本不得反向改变 dbbot 的源码默认变量，源码默认值以对应 `default/` 或 `vars/` 文件为准。

## 跨模块编辑总则
- 只有各模块 `playbooks/` 下顶层入口 playbook 允许直接执行。
- `playbooks/tasks/`、`playbooks/pre_tasks/`、`playbooks/post_tasks/`、`roles/*/tasks/` 下文件默认视为内部复用片段，不单独作为入口。
- 新增核心入口时，必须同步更新对应模块 `AGENTS.md` 的“公开入口”清单、CI 语法检查、发版后检查与相关文档。
- 辅助工具安装入口可直接执行，但不纳入核心公开入口清单，除非它被用户文档、CLI 或 release 流程明确暴露。
- 拓扑、账号、端口、路径优先放在 inventory 或 `vars/*.yml` / `default/*.yml`，避免写死在 task / template 中。
- 模块目录边界要清晰：各模块的 `inventory/`、`downloads/`、`playbooks/`、`roles/`、`examples/` 必须保持在各自子树内，不要混放。
- 公开能力状态必须明确；不可用能力不得保留入口文档、默认变量或看起来可执行的占位实现。
- 不要把 Access Token、密码、私钥写入仓库、文档或任何 `AGENTS.md`。

## Ansible 规则
- 优先采用可幂等、可回放的 Ansible 方案。
- 只有当 `ansible.builtin.*` 或社区 collection 模块无法完成目标时才写 `shell:` / `command:`；一旦写了，必须同时提供 `changed_when` 和合理的 `failed_when`。
- 统一使用 Ansible FQCN 模块（`ansible.builtin.*`）。
- 变量名使用 `lower_snake_case`。
- 新增 role 使用以下命名：
  - `install_<software>`：安装单个软件包或二进制。
  - `setup_<component>`：安装并配置单个组件。
  - `make_<topology>`：编排多节点、多组件拓扑。
- 编辑 role 时沿用对应目录名；不要把无语义裸名词复制成新的 role 命名模式。

## 变更要求
- 不要静默修改生产敏感默认值：
  - 端口
  - 默认密码、默认用户名 / 组
  - 数据目录、socket 路径、systemd unit 名
  - 分片 / 副本逻辑
  - 备份 / 恢复对象范围
- 行为变化必须同步更新：
  - 对应 `default/*.yml` 或 `vars/*.yml`
  - 示例 inventory
  - 相关中英文文档
- 涉及高风险动作时，优先保留：
  - inventory 守卫
  - inventory purpose 守卫
  - 手工确认
- 覆盖系统配置时，优先写受控文件，不直接依赖整个系统配置重载。
- 清理、卸载、删除、恢复、覆盖类能力必须明确：
  - 前置条件
  - 风险范围
  - 回滚或重建方式

## 发版规则
- 本地 release 包统一缓存到：
  - `/mnt/hgfs/packages/db_packages/dbbot_packages`
- 根仓 `dist/` 不作为发版产物目录；不要把 release tarball 放在项目目录里，避免体积膨胀和误提交。
- 推送 release tag 前，必须先在本机生成一份同名 release 包留存：
  - `bash .github/scripts/build-release-package.sh <tag> /mnt/hgfs/packages/db_packages/dbbot_packages`
- `.github/scripts/build-release-package.sh` 未显式传入输出目录时，默认输出到 `/mnt/hgfs/packages/db_packages/dbbot_packages`。
- GitHub release workflow 在 runner 临时目录生成 `dbbot-<tag>.tar.gz`，随后上传到对应 GitHub Release；runner 里的临时包不等于本机留存包。
- 每个 release tag 或 pre-release tag 在推送前必须存在：
  - `.github/release-notes/<tag>.md`
- 所有 release note 必须仅使用英文。
- GitHub auto-generated release notes 不能作为最终 release body。
- release workflow 必须发布 `.github/release-notes/<tag>.md` 的内容，并在其后追加 compare link。
- `.github/release-notes/<tag>.md` 是 release body 的唯一真相源；GitHub Release UI 中的手工编辑不能覆盖受管内容。
- 若 tag 发布后 `.github/release-notes/<tag>.md` 被更新，对应 sync workflow 必须自动更新 GitHub Release body。
- Beta release 不要求固定 section 布局，可以使用自由格式英文总结；comparison baseline 必须是上一个 official release，不能使用 beta release。
- Official release note 只能使用以下 section，并且顺序必须严格一致：
  - `## [Note]`
  - `## [Add]`
  - `## [Change]`
  - `## [Fix]`
  - `## [Remove]`
- Official release note 可以省略空 section；summary baseline 必须是上一个 official release。
- 若不存在上一个 official release，则第一个 official release 的比较范围为整个仓库。
- Official release 不能以 beta release 作为 comparison baseline。
- Git 提交、分支推送、tag 推送优先使用 SSH。

## 校验清单
- 改动 Ansible 代码时，至少执行对应模块 `AGENTS.md` 中列出的 syntax-check。
- 改动 Ansible 代码时，建议本地再跑一次对应子项目的 lint 脚本，例如：
  - `sh /usr/local/dbbot/mysql_ansible/lint_all_yml_files.sh`
- 改动 Hugo 文档站内容时，执行：
  - `cd /usr/local/dbbot_web && npm run build`

## 规则冲突
规则冲突时按以下优先级处理：

1. 用户明确要求
2. 仓内源码、文档和模块 `AGENTS.md`
3. 本文件的跨模块约定
4. 通用 Ansible 最佳实践
