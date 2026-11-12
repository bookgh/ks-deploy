# 总体架构与完整需求规格

- 项目：ks-deploy
- 平台：amd64、Rocky Linux 9
- Kubernetes 目标版本：`v1.37.2`，版本单点定义
- 部署：官方二进制 + Systemd；禁止 kubeadm、k3s、RKE 等封装工具
- 状态：需求基线；功能完成必须以代码、测试和验收报告为证据

## 1. 目标、边界与原则

建设可重复执行、可离线交付、可审计、可滚动升级的 Kubernetes 二进制部署框架。安装节点统一编排；远端节点只接受 SSH 远程命令并从安装节点 Caddy HTTP 服务下载文件，不运行主部署脚本。

禁止：部署阶段在线下载离线制品；SCP/rsync 逐台分发文件；Worker kubeconfig 直连 Master IP；脚本硬编码 IP/网段/版本/Chart 版本；无条件覆盖 PKI、etcd 数据或业务数据；以状态文件代替真实健康检查。

原则：配置单一事实源、制品与部署分离、真实状态优先、先校验再变更、最小权限、失败可恢复、旧版本保留、文档不冒充实现。

## 2. 总体架构

```text
GitHub Actions (只构建制品，不部署集群)
  | 官方二进制 / RPM / Chart / 镜像 / checksum / manifests
  v
GitHub Release -> 离线介质或在线制品准备 -> 安装节点
                                           |
                                  install.sh / step runner
                                           |
                         +-----------------+----------------+
                         |                                  |
                    SSH 远程执行                       Caddy :2026
                         |                                  |
              Master / Worker 节点 <--- HTTP 下载制品、配置、RPM、Chart
                         |
          +--------------+-------------------+
          |                                  |
   Master: etcd + control plane       Worker: runtime + kubelet
          |                                  |
          +------ Calico / CoreDNS / NodeLocal DNSCache
                                           |
                                    Harbor（可选）
```

角色职责：

| 角色 | 职责 |
|---|---|
| 安装节点 | 唯一部署入口、配置解析、预检、SSH 编排、Caddy、制品缓存、报告 |
| Master | etcd、API Server、Controller Manager、Scheduler、kubelet、kube-proxy |
| Worker | 运行时、kubelet、kube-proxy、Nginx stream、业务 Pod |
| Harbor 节点 | 可选私有镜像仓库，可独立部署或与其他节点共置 |

## 3. 配置与版本

根目录配置建议：

- `cluster.env`：节点、IP、网段、目录、开关、运行时、SSH 参数。
- `versions.yaml`：Kubernetes、etcd、containerd、runc、CNI plugins、cfssl、Helm、Caddy、Nginx、Harbor 等版本和官方 URL。
- `charts.yaml`：Calico、CoreDNS、NodeLocal DNSCache 仓库、Chart 名称、精确版本、依赖和镜像策略。
- `config/`：组件配置；`templates/`：Systemd、Caddy、Nginx 等模板。

示例变量结构（仅示意，不能直接作为生产地址/网段）：

```bash
K8S_VERSION="v1.37.2"
ARCH="amd64"
OS_FAMILY="rocky"
OS_MAJOR="9"

INSTALL_NODE_IP="CHANGE_ME"
INSTALL_NODE_USER="root"
CADDY_PORT="2026"
CADDY_ROOT="/srv/ks-deploy"
CADDY_BASE_URL="http://${INSTALL_NODE_IP}:${CADDY_PORT}"

HARBOR_ENABLED="false"
HARBOR_NODE_IP="CHANGE_ME"
HARBOR_DOMAIN="harbor.${HARBOR_NODE_IP}.nip.io"
HARBOR_SCHEME="http"
HARBOR_PROJECT="kubernetes"

CONTAINER_RUNTIME="containerd" # containerd | docker
PROXY_MODE="nftables"          # nftables | ipvs | iptables
IMAGE_MODE="online"            # online | offline-harbor | local-import
OFFLINE_MODE="false"
SELINUX_DISABLE="true"
FIREWALLD_UNINSTALL="true"

POD_CIDR="CHANGE_ME"
SERVICE_CIDR="CHANGE_ME"
CLUSTER_DNS="CHANGE_ME"
CLUSTER_DOMAIN="cluster.local"

PKI_DIR="./pki"
ARTIFACTS_ROOT="./artifacts"
KUBELET_ROOT="/var/lib/kubelet"
CONTAINERD_ROOT="/var/lib/containerd"
DOCKER_ROOT="/var/lib/docker"
ETCD_DATA_DIR="/var/lib/etcd"
```

Master/Worker 使用节点数组定义名称、IP、SSH 用户、角色、etcd member 名称。Master 数量由数组决定；etcd 成员通常采用奇数并确保 quorum。安装节点 IP 与集群节点 IP 分开定义。

Chart “默认最新”只允许发生在初始化版本解析：CI 解析当时最新稳定版本后，将精确版本写入 charts.yaml。部署和 Release 构建必须使用锁定版本，禁止运行时追踪 latest。

## 4. 安装节点、Caddy 与 SSH

Caddy 离线制品包含二进制及运行依赖。安装节点解压后由 Systemd 托管，监听配置化端口（默认 2026），根目录映射到版本化 artifacts、RPM repo、Charts、配置和 manifests。生产默认关闭目录列表，限制访问来源；私钥、CA 私钥、SSH key、kubeconfig 不得位于公开 HTTP 根目录。

URL 由变量派生，例如：

```text
http://INSTALL_NODE_IP:2026/artifacts/K8S_VERSION/...
http://INSTALL_NODE_IP:2026/rpm/OS_MAJOR/...
http://INSTALL_NODE_IP:2026/charts/...
```

所有节点的下载基址、RPM repo、Caddy 监听地址均引用 INSTALL_NODE_IP，禁止硬编码 IP。所有下载必须 SHA256 校验。

SSH 仅负责远程命令执行和 SSH 公钥配置；软件、二进制、Chart、RPM、配置文件均由远端 HTTP 拉取。必须配置连接/命令超时、有限重试、退避、HostKey 校验、日志和退出码。禁止 SCP/rsync 文件传输。对非幂等危险命令不能盲目重试。

预检包含：架构、OS、内核、CPU、内存、磁盘、路由冲突、端口占用、Chrony 时间同步、SSH、Caddy 连通性、资源完整性、RPM 依赖闭包。

## 5. PKI 与证书

使用 CFSSL 自建 CA，至少拆分 Kubernetes Root CA、ETCD CA、Front Proxy CA；ServiceAccount signing key 独立管理；Harbor 证书独立。证书覆盖 API Server serving（所有 VIP/DNS/IP SAN）、etcd server/peer/client、controller-manager、scheduler、kubelet client/server、kube-proxy、admin、front-proxy-client、ServiceAccount key pair，以及 Harbor 域名证书。

用户要求证书有效期 100 年。CFSSL 使用 Go duration，最大时间单位是小时；当前实现使用 `876000h`（100 × 365 天），并在 CI 中使用锁定版本的 CFSSL 实际签发根 CA 和叶证书后比较 NotAfter/NotBefore。不能写不受支持的 `100y`。生成后检查 SAN、KeyUsage、ExtKeyUsage、签发者、链、密钥配对和权限。100 年不是安全最佳实践，必须额外提供证书轮换、到期扫描、CA 私钥离线备份、审计、分阶段替换和回滚。CA 轮换与叶证书轮换是不同流程。kubelet 自动轮换策略与自定义静态长期证书策略必须明确，不能冲突。

`pki/` 存在时逐项校验，不可整个目录存在就无条件跳过；缺项/损坏时停止并要求显式修复策略，不得静默覆盖 CA 私钥。私钥目录 0700、私钥文件 0600。PKI 不得放入 Caddy 公共根目录。

## 6. etcd 与控制平面

etcd 使用官方独立二进制，复用 Master 节点，数据目录与二进制目录分离，ETCD CA 双向 TLS。成员名、peer/client URL、数据目录、快照策略均配置化。Systemd 托管并设置 OOMScore、LimitNOFILE、LimitNPROC、journald。安装后检查 endpoint health/status/member list；定期快照并做恢复演练。成员增删和 quorum 恢复使用专门流程，不得通过清空数据目录修复。

Master kube-apiserver 监听 `0.0.0.0:6443`。启用 TLS、RBAC、Node authorizer、匿名访问关闭、etcd TLS、可配置审计策略和 TLS cipher suites。Controller Manager、Scheduler 使用独立身份 kubeconfig，HA 时启用 leader election。所有服务 Systemd 托管。

admin kubeconfig 在集群就绪后导出至安装节点 `output/kubeconfig/admin.kubeconfig`，权限 0600。Worker kubelet/kube-proxy 使用各自最小权限凭据。Worker kubeconfig 的 server 必须是 `https://127.0.0.1:6443`，不得直连 Master IP。

## 7. Worker Nginx stream

每个 Worker 本地 Nginx stream 监听 127.0.0.1:6443，upstream 从 Master 数组自动生成，支持扩展多个 Master；TLS 由 API Server 终止，Nginx 只转发 TCP。配置长连接、proxy_connect_timeout、proxy_timeout、故障切换。必须区分被动失败检测和主动健康检查：开源 Nginx stream 的主动检查能力依赖版本/模块，不能假设默认存在。使用真实可用配置或选择具备主动检查的组件。配置语法检查通过后 reload。验收单 Master 故障、恢复、连接重建和 API 请求。

## 8. 容器运行时

默认 containerd。containerd、runc、CNI plugins 版本独立锁定；CRI 插件启用，systemd cgroup driver；root/state 可配置，数据目录与二进制解耦；配置 pause 镜像、registry mirror、证书和代理。通过 crictl、ctr 和实际 Pod 启动验证。

Docker 不是 Kubernetes CRI。若选择 Docker 作为运行时，必须同时安装兼容 cri-dockerd 并配置 socket、Systemd、CNI；Docker 仅作为附属工具时，kubelet 不得指向 Docker。只能有一个 kubelet CRI endpoint。

仓库信任：HTTP registry 显式配置 insecure/HTTP endpoint 并限制网络范围；HTTP 是明文，不得描述为 TLS 信任。HTTPS 安装正确 CA 根证书、完整链，校验 SAN。不能“信任不完整链”。Harbor 域名为 `harbor.${HARBOR_NODE_IP}.nip.io`。预生成证书供未来 HTTPS 使用；HTTP 模式下证书不参与当前连接。

## 9. Harbor 与镜像策略

Harbor 可选，官方离线包、版本锁定、数据持久化。初始 HTTP 模式；预生成未来 HTTPS 域名证书。密码/凭据通过安全输入，不得提交仓库或写入日志。

镜像模式互斥：

| 模式 | 条件 | 镜像来源 |
|---|---|---|
| offline-harbor | 离线且 Harbor 启用 | 离线归档导入 Harbor，再从 Harbor 拉取 |
| online | 可联网 | 在线 registry；不使用离线归档 |
| local-import | containerd | 导入本地 image store |

离线且无 Harbor 时不能暗中转为公网拉取；必须启用内部 registry 或明确说明不能满足隔离部署。导入后校验 repository/tag/digest，Chart values 与归档镜像一一对应。

## 10. Helm 扩展组件与镜像闭包

Helm 部署 Calico、CoreDNS、NodeLocal DNSCache。Chart 版本来自 charts.yaml；部署使用本地 Chart tgz，不在线拉 Chart。CI 下载 Chart 与依赖，解析 values/templates/subcharts/hooks/initContainers/sidecars，并渲染最终 manifest 获取镜像引用。仅 grep `image:` 不足以证明完整。Operator 动态创建的镜像需额外清单和安装后运行时镜像差异检查。

镜像清单记录原始引用、registry/repository/tag、OCI digest、归档引用、归档 SHA256、来源 Chart/版本。OCI digest 与归档文件 SHA256 是不同概念。Calico、kube-proxy 模式、内核、NodeLocal DNSCache 和 nftables/iptables 行为必须有兼容矩阵及真实环境测试。Pod CIDR、Service CIDR、Cluster DNS、NodeLocal 地址均配置化并查冲突。

## 11. kube-proxy

支持 nftables（默认）、ipvs、iptables。必须显式配置 mode，不依赖 Kubernetes 默认值。预检内核、nft/ipvs 工具和模块。按模式加载内核模块并验证。切换模式是网络变更：备份、检查依赖、节点级切换，验证 ClusterIP、NodePort、DNS、跨节点 Pod 和 NetworkPolicy。不得无边界 flush 全局规则。

## 12. 系统初始化（01-init-system.sh）

按开关卸载 firewalld、关闭 SELinux（默认用户要求执行）；但生产安全建议优先保留 SELinux Enforcing 并适配策略，防火墙用明确规则管理。若关闭必须在文档中警示风险。

配置内核模块、sysctl（ip_forward、bridge-nf-call-iptables/ip6tables、ip_local_port_range、somaxconn、tcp_max_syn_backlog、netdev_max_backlog、keepalive、conntrack 等）、PAM/Systemd limits（nofile、nproc、locks）、TCP 参数、Chrony、hostname 和 /etc/hosts。参数按 Master/Worker/安装节点角色设置，检查内核支持，不盲目设极大值。Systemd 服务必须显式 LimitNOFILE/LimitNPROC 并验证生效。

## 13. RPM 与离线制品

RPM 最小集合可配置：chrony、带 stream 模块 nginx、nftables/IPVS 工具和内核模块依赖、基础网络工具、Caddy 运行依赖等。针对目标 Rocky 9 解析完整依赖闭包，禁止 groupinstall 和无关 RPM。

制品独立分包：Kubernetes 二进制；基础二进制（etcd/containerd/runc/CNI/cfssl/helm/caddy/nginx）；RPM 集合；Harbor 离线包；每个 Chart tgz；每组件镜像归档；软件清单、镜像清单、SHA256SUMS。Release 附软件名、版本、官方 URL、SHA256、架构和镜像 digest 清单。

GitHub Actions 只做：读取配置、验证锁定版本、下载官方制品、校验上游签名/checksum、解析 Chart 和镜像、生成 manifests、打包、上传 Release。不得连接集群、SSH 或部署。构建失败不得发布不完整 Release。用户明确要求构建 Release 时直接触发；不触发无关 Release。

## 14. 脚本清单与执行顺序

| 脚本 | 职责 |
|---|---|
| 00-prepare-install-node.sh | 预检、制品下载/校验、SSH key、Caddy |
| 01-init-system.sh | 系统优化、Chrony、hostname/hosts |
| 02-gen-ca-and-certs.sh | CFSSL CA 和组件证书 |
| 03-deploy-harbor.sh | 可选 Harbor、证书、仓库信任、镜像导入 |
| 04-deploy-etcd.sh | Master etcd |
| 05-deploy-k8s-control-plane.sh | API Server、Controller Manager、Scheduler |
| 06-deploy-container-runtime.sh | 全节点运行时、仓库信任、CNI plugins |
| 07-deploy-kubelet-kubeproxy.sh | 全节点 kubelet、kube-proxy |
| 08-deploy-worker-nginx-proxy.sh | Worker 本地 Nginx stream |
| 09-deploy-addons.sh | Calico、CoreDNS、NodeLocal DNSCache |
| 10-cluster-check.sh | 全量验收 |
| 11-rotate-certificates.sh | 独立证书轮换 |
| 00-clean-cluster.sh | 幂等清理，危险操作确认 |

另有 `bin/install.sh` 一键入口、`bin/deploy-step.sh` 分步入口。

实际依赖顺序不能机械按文件编号：准备安装节点 -> 系统初始化 -> 证书 -> Harbor（可选）-> etcd -> 容器运行时 -> 控制平面 -> Nginx stream（必须早于 Worker kubelet 使用 localhost API）-> kubelet/kube-proxy -> addons -> 导出 kubeconfig -> 全量验收。实现可保留用户脚本编号，但 orchestrator 按依赖图调度。Master kubelet 同样依赖 CRI。

所有脚本 Bash `set -euo pipefail`，支持 `--dry-run`、颜色日志（非 TTY 禁色）、进度 `[01/XX]`、超时重试、日志、统一错误处理、SHA256 强校验。Dry-run 不得写文件、安装 RPM、导入镜像、启服务或修改远端。变更前备份。满足真实目标状态才输出“已安装并跳过”。状态文件仅提示，必须重新检查真实状态。

示例入口：

```bash
./bin/install.sh --dry-run
./bin/install.sh
./bin/install.sh --skip 03,04
./bin/deploy-step.sh 04
./scripts/09-deploy-addons.sh calico
./scripts/09-deploy-addons.sh coredns
./scripts/09-deploy-addons.sh nodelocaldns
./scripts/10-cluster-check.sh
```

## 15. Systemd、安全与输出

etcd、API Server、Controller Manager、Scheduler、kubelet、运行时、Nginx、Caddy 使用 Systemd 模板；配置 Restart、OOMScoreAdjust、LimitNOFILE、LimitNPROC、依赖、权限、环境文件和 journald。不得在 unit/log 中写密码、token、私钥。

控制面启用 RBAC、Node authorizer、关闭匿名访问；审计可配置。admin kubeconfig 仅输出安装节点，0600。SSH HostKey 校验开启。HTTP Caddy/Harbor 限制在受控网络，checksum 不替代来源签名或 TLS。

## 16. 验收

10-cluster-check.sh 至少验证：

1. Caddy、各节点 HTTP 下载、SHA256、RPM 完整性。
2. OS/架构/内核/CPU/内存/磁盘/时间同步。
3. SSH 和节点间网络。
4. etcd health/status/member list。
5. API Server /livez、/readyz。
6. Controller Manager、Scheduler、kubelet、CRI 服务。
7. 节点 Ready。
8. Calico 节点、跨节点 Pod 通信。
9. CoreDNS、NodeLocal DNSCache。
10. ClusterIP、NodePort、Service DNS、外部 DNS。
11. Harbor 登录、镜像拉取、digest（启用时）。
12. Worker kubeconfig localhost endpoint、Nginx upstream 故障切换。
13. 证书期限、SAN、权限、审计和端口。
14. 临时 Deployment/Service 端到端测试并清理。

输出文本和 JSON 报告；关键项全部通过才报告成功。

## 17. 升级、回滚与清理

每个版本单独存放于 `artifacts/${K8S_VERSION}/`，旧版本不覆盖。遵循官方 Version Skew Policy 和受支持升级路径，逐 Minor 升级。升级前检查 API 弃用、etcd、CNI、CRI、Chart、内核和代理模式兼容性。先备份并验证 etcd 快照；HA 控制平面滚动升级；Worker 逐节点 cordon/drain、升级 kubelet/kube-proxy、验证后 uncordon。数据目录与二进制解耦。二进制回滚不代表 API 数据库自动回滚，etcd 恢复必须独立执行。

清理分级：停服务、删二进制、删配置、删证书、删 etcd 数据、删容器数据、删 Harbor 数据。默认只停服务；删除数据显示目标路径、检查备份并二次确认。

## 18. 目录建议

```text
ks-deploy/
├── README.md
├── cluster.env
├── versions.yaml
├── charts.yaml
├── bin/{install.sh,deploy-step.sh,preflight.sh,common.sh}
├── scripts/{00-prepare-install-node.sh,00-clean-cluster.sh,01-init-system.sh,02-gen-ca-and-certs.sh,03-deploy-harbor.sh,04-deploy-etcd.sh,05-deploy-k8s-control-plane.sh,06-deploy-container-runtime.sh,07-deploy-kubelet-kubeproxy.sh,08-deploy-worker-nginx-proxy.sh,09-deploy-addons.sh,10-cluster-check.sh,11-rotate-certificates.sh}
├── config/
├── templates/{systemd,caddy,nginx,etcd,kubernetes,containerd,harbor}/
├── pki/                         # 私密，不入 Git
├── artifacts/${K8S_VERSION}/   # 制品，不入 Git
├── output/                      # kubeconfig/log/report，不入 Git
├── state/
├── docs/
└── .github/workflows/build-offline-artifacts.yml
```

.gitignore 必须排除 pki、artifacts、output、state、kubeconfig、私钥、SSH key、token、日志和真实凭据。CFSSL JSON 模板只提交占位符和公开配置，不提交生成密钥。

## 19. 必须持续审查的风险

- v1.37.2 官方发布资产、依赖矩阵和 checksum 必须在 CI 验证，不能猜 URL。
- Rocky 9 实际内核、nftables/IPVS、Calico、NodeLocal DNS 组合必须实测。
- Nginx 开源版主动健康检查能力不能假设存在。
- Chart 静态解析无法保证覆盖 operator 动态镜像。
- Docker 运行时必须配 cri-dockerd。
- HTTP registry 是明文；HTTPS 必须正确 CA 和完整链。
- 100 年证书提高私钥长期暴露风险。
- 关闭 SELinux/firewalld 是用户要求但非安全最佳实践。
- Worker Nginx 必须早于 kubelet localhost API 连接；运行时必须早于 kubelet。

## 20. 完成定义

功能只有在代码实现、静态检查、自动化测试、Rocky Linux 9 目标环境验证、文档同步和风险记录均完成后，才能标记“已完成”。文件存在不代表功能已实现。

