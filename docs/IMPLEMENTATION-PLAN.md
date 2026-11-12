# 实施里程碑、验收与状态跟踪

> 本文件是项目进度记录。初始状态全部为“未开始”；只有代码和测试证据齐备后才能改为完成。

## 状态定义

- [ ] 未开始
- [~] 开发中
- [x] 已实现且通过列出的验证
- [!] 已实现但未验证 / 存在阻塞

## M0：仓库基础与工程规范

**范围**
- [x] .gitignore（排除 pki、artifacts、output、state、kubeconfig、私钥和凭据）
- [x] cluster.env.example
- [x] versions.yaml
- [x] charts.yaml
- [x] 配置 schema / 校验器（严格 KEY=value 解析、YAML 唯一键、类型/枚举/网络/版本/来源校验）
- [x] ShellCheck、shfmt、bash -n 基础 CI
- [x] 测试目录和贡献/开发说明

**验收**
- [x] 配置缺项、未知值、重复节点 IP、非法 CIDR、版本空值能明确失败。
- [x] 真实 secret 不会被提交（忽略规则覆盖运行配置、PKI、制品、输出、状态、kubeconfig、私钥和 token）。
- [x] GitHub Actions CI run #3 已通过配置校验、16 项单元测试、CLI smoke test、bash -n、ShellCheck 与 shfmt。

## M1：公共执行框架、安装节点和 Caddy

**范围**
- [~] bin/common.sh：日志、颜色、进度、错误 trap、Dry-run、备份、SHA256、flock 部署互斥锁
- [~] bin/install.sh 与 bin/deploy-step.sh 依赖顺序编排骨架
- [ ] SSH executor：超时、有限重试、HostKey 校验、远端安全命令执行
- [~] 00-prepare-install-node.sh：校验并部署锁定 Caddy 制品；SSH key 管理与实机验收未完成
- [~] Caddyfile、Systemd unit（由安装脚本生成；需 Rocky 9 实机验证）
- [ ] RPM repo 配置模板
- [ ] 远端 HTTP 下载与校验函数

**验收**
- Dry-run 对本机和远端均无副作用。
- HTTP 资源下载后 SHA256 不匹配会失败。
- SSH 不可达、HostKey 不匹配、超时均有明确错误。
- 文件只通过 HTTP 分发，不使用 SCP/rsync。
- Caddy 由 Systemd 托管，安装节点端口可达性检查通过。

当前 M1 尚未达到验收完成：公共函数库、依赖顺序调度骨架、部署互斥锁和安装节点准备脚本已实现；其余阶段脚本尚未实现。SSH 连通性、HostKey 错误分类、实际 HTTP 服务和 Caddy systemd 行为尚无 Rocky 9 集成验证；不得把 M1 标为完成。

互斥锁使用 `flock` 锁定本地配置的 `KS_LOCK_FILE`（默认 `/tmp/ks-deploy.lock`），一键流程持锁贯穿子步骤；独立分步入口也会获取同一把锁。Dry-run 不创建锁目录或文件。自动化测试覆盖并发拒绝和 Dry-run 无文件副作用。

版本解析准备：已从 Caddy 官方 Release `v2.11.9` 固定 amd64 tarball、checksum 清单、Sigstore 签名和证书的 URL 与 SHA256。准备脚本要求 cosign 验证两个签名的证书身份/发行者，再以已签名的 checksum 清单比对 tarball 哈希；组件 source URL 缺少 SHA256 时配置校验失败。哈希来自 GitHub 官方 Release API 资产 digest。

## M2：系统初始化与 PKI

**范围**
- [~] 01-init-system.sh：SSH 远端校验、HTTP/SHA256 拉取配置、Master/Worker 幂等应用
- [~] sysctl、模块、limits、Chrony、hostname/hosts 配置；Rocky 9 实机结果待验证
- [ ] CFSSL CA 配置和证书 profile
- [ ] 02-gen-ca-and-certs.sh
- [ ] 11-rotate-certificates.sh
- [ ] 证书检查与权限检查

**验收**
- [ ] Rocky Linux 9 目标节点预检通过（远端实机尚未连接验证）。
- 重复运行不会覆盖有效证书或重复写入配置。
- 证书 SAN、用途、有效期、链和私钥配对检查通过。
- 100 年 duration 格式经过 CFSSL 实际测试。
- 轮换演练包含备份、签发、分发、重启、验证和回滚。

`01-init-system.sh` 已生成带集群节点映射的 `/etc/hosts` 管理块、内核模块/sysctl、limits 和 Chrony 配置；由安装节点 Caddy 暴露配置文件，远端先验证 SHA256 再应用。它按 `SWAP_DISABLE` 关闭运行时 swap 并备份后注释 `/etc/fstab` swap 项。Dry-run 仅展示 SSH 命令，不创建 staging 文件。SELinux/firewalld 依据现有开关处理；SELinux 从 enforcing 转为 disabled 仍需重启，firewalld 开关为 true 时会通过 dnf 删除软件包。目标机需预装 chrony、curl、Python 3 和 Rocky 9 基础工具。该实现尚未在 Rocky Linux 9 远端节点执行，不能视为 M2 验收通过。

## M3：etcd、容器运行时与控制平面

**范围**
- [ ] 04-deploy-etcd.sh
- [ ] 06-deploy-container-runtime.sh（containerd）
- [ ] Docker + cri-dockerd 可选路径
- [ ] 05-deploy-k8s-control-plane.sh
- [ ] Systemd templates
- [ ] kubeconfig 生成器

**验收**
- etcd 多成员健康、TLS、快照与恢复演练通过。
- containerd CRI 正常，Pod sandbox 能启动。
- API Server /readyz 成功，Controller Manager/Scheduler 正常。
- RBAC、Node authorizer、anonymous-auth=false 生效。
- Systemd Limit/OOM 配置实际生效。
- admin kubeconfig 只输出安装节点，0600。

## M4：节点代理、kubelet 与 kube-proxy

**范围**
- [ ] 08-deploy-worker-nginx-proxy.sh
- [ ] 07-deploy-kubelet-kubeproxy.sh
- [ ] nftables / ipvs / iptables 配置
- [ ] Worker kubeconfig localhost endpoint
- [ ] Master/Worker 启动依赖编排

**验收**
- Worker kubeconfig server 精确为 https://127.0.0.1:6443。
- Worker Nginx stream upstream 从 Master 数组生成。
- 单 Master 故障和恢复测试通过。
- kubelet CRI endpoint 正确，节点 Ready。
- kube-proxy 模式、内核模块、Service/NodePort 验证通过。

## M5：Harbor、Helm Charts 与镜像供应链

**范围**
- [ ] 03-deploy-harbor.sh
- [ ] HTTP registry 信任配置 / HTTPS CA 信任配置
- [ ] 镜像归档导入 Harbor
- [ ] charts.yaml 锁定
- [ ] 09-deploy-addons.sh
- [ ] Calico、CoreDNS、NodeLocal DNSCache values
- [ ] Chart 镜像清单和 digest 校验

**验收**
- Harbor HTTP/HTTPS 模式行为符合配置，HTTP 明文风险有说明。
- 离线归档镜像能导入并按 digest 拉取。
- Chart 本地安装，不访问 Chart 网络源。
- values 中的镜像引用与镜像归档清单一致。
- operator 动态镜像差异得到检查。
- Pod 网络、跨节点通信、Service、DNS、NetworkPolicy 通过。

## M6：离线制品 GitHub Actions

**范围**
- [ ] .github/workflows/build-offline-artifacts.yml
- [ ] 官方下载地址和版本清单
- [ ] 上游签名/checksum 校验
- [ ] RPM 依赖闭包构建
- [ ] Chart 下载、依赖解析、模板渲染
- [ ] 镜像拉取、digest 和 archive checksum
- [ ] Release 上传

**验收**
- Actions 只构建制品，不连接集群。
- 所有来源可追溯到官方源。
- 所有制品 checksum 可复验。
- 离线包在断网环境完成一次安装验收。
- 用户未授权时不触发 Release。

## M7：完整验收、升级、恢复与文档

**范围**
- [ ] 10-cluster-check.sh
- [ ] 00-clean-cluster.sh
- [ ] docs/offline-install.md
- [ ] docs/upgrade.md
- [ ] docs/certificate-rotation.md
- [ ] docs/troubleshooting.md
- [ ] docs/validation-checklist.md
- [ ] 升级与回滚脚本/流程
- [ ] 部署报告

**验收**
- 完整一键部署和分步部署均通过。
- 在线模式与离线 Harbor 模式分别通过。
- 重复执行和中断恢复测试通过。
- Kubernetes 版本倾斜和升级路径检查通过。
- etcd 快照恢复、证书轮换、节点故障和 API 代理切换演练通过。
- 所有文档与真实实现一致。

## 每个里程碑的强制交付记录

完成每个里程碑时，在下方追加：

```text
### Mx - YYYY-MM-DD
- 状态：
- 变更文件：
- 实现内容：
- 验证命令：
- 验证结果：
- 未执行/未验证：
- 遗留风险：
- Commit：
```

## 当前进度

### M0 - 2026-11-12
- 状态：M0 工程基础、配置校验和 GitHub Actions CI 全部通过；尚未在 Rocky Linux 9 目标主机执行集群部署，因此不代表生产部署验证完成。
- 变更文件：`.gitignore`、`cluster.env.example`、`versions.yaml`、`charts.yaml`、`tools/validate_config.py`、`tests/`、`Makefile`、`requirements-dev.txt`、`.github/workflows/ci.yml`、`CONTRIBUTING.md`、`README.md`。
- 实现内容：建立安全忽略规则；严格解析且不执行 `KEY=value` 环境配置；校验缺项、未知项、非法字符、枚举、节点名称/IP 唯一性、CIDR 语法与重叠、DNS、路径、运行时/离线模式组合；严格校验 SemVer、HTTPS 来源、YAML 重复键和 Chart 版本锁定状态；Chart 源地址按官方文档修正。
- 验证命令：`make validate`、`make test`、`PYTHON=python3 bash tests/test-config-cli.sh`、`make lint`、`git diff --cached --check`。
- 验证结果：本地配置校验通过；16 项 Python 单元测试通过；CLI 正向及空版本负向 smoke test 通过；GitHub Actions run [#3](https://github.com/bookgh/ks-deploy/actions/runs/43211713307) 全部通过，包含配置校验、16 项测试、ShellCheck、shfmt 和 Bash 语法检查。Git 忽略规则已核验运行配置、PKI、制品、输出、kubeconfig、PEM/P12/PFX 私钥及凭据文件。
- 未执行/未验证：未在 Rocky Linux 9 真实主机开展系统初始化、二进制部署、etcd、CRI、CNI 或离线安装测试；这些属于后续里程碑及目标环境验收。
- 遗留风险：etcd、运行时、CFSSL、Helm 和 Chart 版本仍需按官方来源及 Kubernetes v1.37.2 兼容性矩阵审查后锁定；NodeLocal DNSCache 本地 Chart 将在 M5 实现；当前仅锁定 Kubernetes v1.37.2。
- Commit：M0 实现 `c5d7faa`；CI 缓存修复 `3adbff3`；SemVer、密钥忽略及 Chart 来源收尾 `e53a1a4`。

### 需求与架构归档 - 2026-11-12
- 状态：初始设计文档已提交；部署代码当时尚未开始。
- 文件：README.md、docs/ARCHITECTURE.md、docs/IMPLEMENTATION-PROMPT.md、docs/IMPLEMENTATION-PLAN.md。
- 验证：通过 GitHub 仓库文件/提交结果确认文档提交；当时尚无脚本可执行测试。
- 下一步：M1，实施公共执行框架、安装节点预检、SSH 执行器及 Caddy HTTP 制品分发。
- 遗留风险：目标 Kubernetes/etcd/Calico/Helm Chart 版本兼容性需按官方发布信息确认；Rocky Linux 9 目标环境尚未进行安装测试。

### M1 基础库 - 2026-11-12
- 状态：部分实现；M1 验收未完成。
- 变更文件：`bin/common.sh`、`tests/test-common.sh`、`Makefile`、`README.md`、`CONTRIBUTING.md`、`docs/IMPLEMENTATION-PLAN.md`。
- 实现内容：加入严格配置键允许列表与字面值解析、非 TTY 颜色日志、步骤进度、统一错误 trap、Dry-run 命令包装、备份、HTTP(S) 下载及 SHA256 验证、启用 HostKey 严格检查的 SSH 执行基础。下载失败采用有限重试；SSH 重试次数由调用方明确提供。
- 验证命令：`make check`（新增 Bash 自动化测试已接入 `make test`，并由 GitHub Actions 运行）。
- 验证结果：本地 Windows 环境未提供 Bash、ShellCheck、shfmt 或 GNU Make；GitHub Actions run [#43218399581](https://github.com/bookgh/ks-deploy/actions/runs/43218399581) 通过配置校验、16 项 Python 测试、CLI smoke test、Bash 自动化测试、`bash -n`、ShellCheck 和 shfmt。
- 未执行/未验证：未验证 Rocky Linux 9；未实测 SSH HostKey、超时、远端退出或 HTTP 下载；未启动 Caddy。
- 遗留风险：尚未实现文件锁、SSH key 配置、RPM repo、远端 HTTP 测试；安装脚本依赖 Rocky 9 上预装的 cosign、PyYAML、curl 等工具，需补离线依赖闭包和主机实测；不满足完整 M1 验收，更不代表集群部署完成。
- Commit：本轮主提交 `e493360`；换行修复 `6418ec6`；错误处理及静态检查收尾 `9d8560e`、`3540965`、`b1c1829`、`cf57510`、`121ebdc`。

