# 开发与贡献说明

## 开发环境

- Python 3.9 或更高版本
- Bash 4 或更高版本
- ShellCheck
- shfmt
- Git

建议使用虚拟环境安装开发依赖：

```bash
python3 -m venv .venv
source .venv/bin/activate
make install-dev
```

## 配置文件

1. 将 `cluster.env.example` 复制为 `cluster.env`，填写实际节点、网段和目录。
2. `cluster.env` 是严格的 `KEY=value` 文件，不是通用 Shell 脚本；不要写命令替换、变量展开或执行语句。
3. `versions.yaml` 是组件版本唯一事实源。只有完成官方来源、checksum/签名及兼容性审查后才能锁定版本。
4. `charts.yaml` 先登记仓库与 Chart 名称；`version_lock_status: pending` 表示尚未完成兼容性审查。改为 `locked` 时必须填写精确 SemVer 版本。
5. 不要提交真实 IP、密码、Token、SSH 私钥、CA 私钥、PKI、kubeconfig 或离线制品。

## 本地检查

```bash
make install-dev
make validate
make test
make lint
# 或一次执行全部检查
make check
```

指定自定义配置：

```bash
make validate CONFIG_ENV=cluster.env CONFIG_VERSIONS=versions.yaml CONFIG_CHARTS=charts.yaml
```

配置校验器仅解析受限的 `KEY=value` 格式和 YAML，不执行配置文件内容。校验失败时返回非零状态码。

## 开发约定

- 先读现有实现，再做最小范围修改。
- Bash 脚本使用 `set -euo pipefail`，4 空格缩进，必须通过 `bash -n`、ShellCheck 和 shfmt。
- 不允许通过 SCP/rsync 分发文件；远端文件通过安装节点 HTTP 服务获取并校验 SHA256。
- Dry-run 不得产生本地或远端副作用；幂等判断必须核验真实状态。
- 完成功能、测试、文档和里程碑记录后再集中提交；commit message 使用中文并直接提交 main。
- 不因普通 CI 或代码变更触发 Release 制品构建。
