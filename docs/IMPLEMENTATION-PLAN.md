# 实施里程碑、验收与状态跟踪

> 本文件是项目进度记录。初始状态全部为“未开始”；只有代码和测试证据齐备后才能改为完成。

## 状态定义

- [ ] 未开始
- [~] 开发中
- [x] 已实现且通过列出的验证
- [!] 已实现但未验证 / 存在阻塞

## M0：仓库基础与工程规范

**范围**
- [ ] .gitignore（排除 pki、artifacts、output、state、kubeconfig、私钥和凭据）
- [ ] cluster.env.example
- [ ] versions.yaml
- [ ] charts.yaml
- [ ] 配置 schema / 校验器
- [ ] ShellCheck、shfmt、bash -n 基础 CI
- [ ] 测试目录和贡献/开发说明

**验收**
- 配置缺项、未知值、重复节点 IP、非法 CIDR、版本空值能明确失败。
- 真实 secret 不会被提交。
- shellcheck/shfmt/baseline tests 在 CI 通过。

## M1：公共执行框架、安装节点和 Caddy

**范围**
- [ ] bin/common.sh：日志、颜色、进度、错误 trap、Dry-run、锁、备份、SHA256
- [ ] bin/install.sh 与 bin/deploy-step.sh 基础编排
- [ ] SSH executor：超时、有限重试、HostKey 校验、远端安全命令执行
- [ ] 00-prepare-install-node.sh
- [ ] Caddyfile、Systemd unit
- [ ] RPM repo 配置模板
- [ ] 远端 HTTP 下载与校验函数

**验收**
- Dry-run 对本机和远端均无副作用。
- HTTP 资源下载后 SHA256 不匹配会失败。
- SSH 不可达、HostKey 不匹配、超时均有明确错误。
- 文件只通过 HTTP 分发，不使用 SCP/rsync。
- Caddy 由 Systemd 托管，安装节点端口可达性检查通过。

## M2：系统初始化与 PKI

**范围**
- [ ] 01-init-system.sh
- [ ] sysctl、模块、limits、Chrony、hostname/hosts 模板
- [ ] CFSSL CA 配置和证书 profile
- [ ] 02-gen-ca-and-certs.sh
- [ ] 11-rotate-certificates.sh
- [ ] 证书检查与权限检查

**验收**
- Rocky Linux 9 目标节点预检通过。
- 重复运行不会覆盖有效证书或重复写入配置。
- 证书 SAN、用途、有效期、链和私钥配对检查通过。
- 100 年 duration 格式经过 CFSSL 实际测试。
- 轮换演练包含备份、签发、分发、重启、验证和回滚。

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

### 需求与架构归档 - 2026-11-12
- 状态：文档已提交；部署代码尚未开始。
- 文件：README.md、docs/ARCHITECTURE.md、docs/IMPLEMENTATION-PROMPT.md、docs/IMPLEMENTATION-PLAN.md。
- 验证：通过 GitHub 仓库文件/提交结果确认文档提交；尚无脚本可执行测试。
- 下一步：M0，建立配置模板、.gitignore、配置校验和 Shell CI。
- 遗留风险：目标 Kubernetes/etcd/Calico/Helm Chart 版本兼容性需按官方发布信息确认；Rocky Linux 9 目标环境尚未进行安装测试。
