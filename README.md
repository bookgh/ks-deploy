# ks-deploy

> Rocky Linux 9 / amd64 的 Kubernetes 原生二进制部署框架。目标 Kubernetes 版本：`v1.37.2`。禁止使用 kubeadm、k3s、RKE 等集群封装工具。

**当前阶段：M0 已完成；M1 安装节点准备与依赖调度器进行中。** 公共库、依赖顺序调度入口和 `scripts/00-prepare-install-node.sh` 已提供基础实现：固定校验 Caddy 制品与 Sigstore 签名、配置 systemd HTTP 服务。其他阶段脚本尚未实现；这不代表 Kubernetes 集群部署、离线制品闭包或 Rocky Linux 9 实机验收已经完成。

## 文档导航

- [总体架构与完整需求规格](docs/ARCHITECTURE.md)
- [后续会话使用的实施提示词](docs/IMPLEMENTATION-PROMPT.md)
- [里程碑、验收与实施顺序](docs/IMPLEMENTATION-PLAN.md)
- [开发与贡献说明](CONTRIBUTING.md)

## 核心设计

- 安装节点统一编排；远端节点只接收 SSH 远程命令并通过安装节点 Caddy HTTP 服务拉取文件，不运行主部署脚本。
- Kubernetes、etcd、运行时等使用官方二进制/制品，Systemd 管理组件生命周期。
- 默认 containerd；Docker 仅作为可选 CRI 方案（通过 cri-dockerd），或作为非运行时附属工具。
- etcd 独立二进制部署并复用 Master 节点；CFSSL 自建分层 CA。
- Worker kubeconfig 固定指向本机 `127.0.0.1:6443`，由 Nginx stream 代理到 Master API Server。
- Helm 部署 Calico、CoreDNS、NodeLocal DNSCache；Chart 版本统一从配置读取。
- 在线/离线制品分离；GitHub Actions 只负责获取官方制品、校验、解析镜像、打包并发布 Release，不部署集群。
- 幂等、SHA256 校验、Dry-run、分步执行、状态检查、版本隔离和滚动升级是强制要求。

## 配置与本地校验

```bash
cp cluster.env.example cluster.env
python3 -m venv .venv
source .venv/bin/activate
make install-dev
make check
```

`cluster.env` 使用严格的 `KEY=value` 格式，配置校验器不会执行其中的内容。公共 Bash 库也只解析允许列表中的字面值，不使用 `source` 或 `eval`。`versions.yaml` 是组件版本的唯一事实源；已登记的 Caddy `v2.11.9` 固定了官方 amd64 制品地址和 SHA256。Chart 只有在完成兼容性审查后才能设置精确版本并标记为 `locked`。详细说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

CI 在 push 到 `main`、Pull Request 和手动触发时执行配置校验、Python 单元测试、`bash -n`、ShellCheck 与 shfmt。CI 不会构建或发布 Release。

## 从新会话继续

关闭 ChatGPT 窗口后重新开始时：

1. 打开本仓库，先阅读 [ARCHITECTURE.md](docs/ARCHITECTURE.md)、[IMPLEMENTATION-PROMPT.md](docs/IMPLEMENTATION-PROMPT.md)、[IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md)。
2. 要求先检查仓库现状，再继续实施。不要让模型凭空假设脚本已经存在。
3. 每次只推进一个可验证里程碑；完成后更新文档、执行测试，再按中文提交说明直接提交 `main`。

建议新会话提示词：

```text
请继续开发 https://github.com/bookgh/ks-deploy.git。
先读取 main 分支 README.md、CONTRIBUTING.md、docs/ARCHITECTURE.md、
docs/IMPLEMENTATION-PROMPT.md、docs/IMPLEMENTATION-PLAN.md，以及仓库中已经存在的代码和最近提交。
以仓库内容为唯一项目事实来源，不要假设未实现的脚本或功能已经存在。
先汇报当前已实现、未实现、存在风险和下一步最小可交付任务；
然后按 IMPLEMENTATION-PROMPT.md 的约束继续开发。
直接提交 main，中文 commit message，不创建分支或 PR；
不触发与当前需求无关的 Release。需要构建 Release 时按文档授权直接执行。
编码后必须运行适用的静态检查、ShellCheck、shfmt、配置校验和可执行的集成测试，
更新文档与验收状态后再提交。
```

## 重要原则

- 所有版本、IP、网段、目录、Chart 版本和开关均配置化，禁止在脚本中散落硬编码。
- 不允许以状态标记文件代替真实状态检查。
- 不允许覆盖已有 PKI、etcd 数据、业务容器数据或未备份配置。
- 离线模式必须证明制品闭包完整；禁止部署时临时联网下载离线制品。
- 所有危险清理、证书轮换、etcd 恢复和版本回滚都必须有显式保护与操作手册。
- 100 年证书有效期是用户给定的兼容性要求，不是安全最佳实践；必须额外设计短期叶证书轮换、CA 私钥保护和到期监控。
