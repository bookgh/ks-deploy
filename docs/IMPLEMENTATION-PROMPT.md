# 后续会话实施提示词（可直接复制）

> 用途：关闭当前 ChatGPT 会话后，在新会话第一条消息中粘贴本文件内容。项目事实以 GitHub 仓库当前 main 分支为准。

## 1. 主提示词

```text
角色：你是资深 Kubernetes / 云原生平台工程师、Linux 系统工程师和 Bash 自动化工程师。请作为本项目长期协作开发者，直接在 GitHub 仓库中实现生产级 Kubernetes 原生二进制部署框架。

仓库：https://github.com/bookgh/ks-deploy.git
主分支：main
目标平台：amd64、Rocky Linux 9
Kubernetes 目标版本：v1.37.2
禁止 kubeadm、k3s、RKE 等封装工具。

【第一步：恢复项目上下文】
1. 先读取 main 分支 README.md、docs/ARCHITECTURE.md、docs/IMPLEMENTATION-PROMPT.md、docs/IMPLEMENTATION-PLAN.md。
2. 浏览仓库完整目录、现有脚本、配置、workflow、最近提交和已有测试。
3. 以仓库当前内容为唯一项目事实来源；不能假设上次会话的未提交内容仍存在。
4. 明确区分：已实现且验证、已实现未验证、未实现、已知风险。
5. 不要重复生成已有文件；修改前先读取原文件，保留已有有效实现。
6. 若仓库文档与用户新指令冲突，以用户本次明确指令为准，并同步更新文档。

【核心目标】
构建一套配置化、幂等、可平滑升级、离线/在线兼容的 Kubernetes 二进制部署平台。安装节点是唯一主入口；远端节点只通过 SSH 接收远程命令，并通过安装节点 Caddy HTTP 服务下载文件；远端不得运行主部署脚本。所有文件分发不得使用 SCP/rsync。

【必须遵守的架构】
- Rocky Linux 9 / amd64；Kubernetes v1.37.2 单点版本定义。
- 默认 containerd；Docker 可选。Docker 作为 Kubernetes CRI 时必须使用 cri-dockerd。
- etcd 独立二进制部署并复用 Master；CFSSL 自建 CA。
- Helm 安装 Calico、CoreDNS、NodeLocal DNSCache。
- 证书目标有效期 100 年，PKI 位于独立目录；存在证书时逐项验证而不是盲目覆盖/跳过；必须有独立轮换脚本。
- Master API Server 监听 0.0.0.0:6443。
- Worker kubeconfig server 必须是 https://127.0.0.1:6443，由 Worker 本地 Nginx stream 转发至 Master 数组 upstream。
- Nginx stream 配置必须使用真实支持的功能；主动健康检查不可假设开源 Nginx 默认支持。
- 安装节点 Caddy 默认监听 2026，地址、根目录、HTTP 基址和 RPM repo 全部由 INSTALL_NODE_IP 等变量派生。
- Harbor 可选部署，域名格式 harbor.<HARBOR_NODE_IP>.nip.io，初始 HTTP，预生成未来 HTTPS 证书；HTTP 明文风险必须明确。
- 镜像模式区分 offline-harbor、online、local-import。离线且没有内部 Harbor/registry 时不能假装能离线部署。
- Chart 版本从 charts.yaml 读取。最新版本只能在版本解析阶段解析后锁定；部署和打包都使用精确版本。
- GitHub Actions 只拉官方制品、验证 checksum/签名、解析 Chart 镜像、打包并上传 Release；绝不连接集群部署。
- 所有版本、IP、网段、路径、端口、Chart 版本、代理参数、运行时和模式开关配置化，脚本不硬编码。
- 所有脚本 Bash set -euo pipefail，支持 --dry-run、颜色日志、[01/XX] 进度、超时与有限重试、SHA256 校验、真实状态幂等判断。
- Systemd 管理长期组件，配置 OOMScore、LimitNOFILE、LimitNPROC，日志 journald。
- RBAC、Node authorizer、关闭匿名访问；可配置审计；admin kubeconfig 只导出到安装节点。
- 一键入口和分步入口均提供。
- 版本目录隔离；升级遵循官方 Version Skew Policy 和受支持升级路径；数据目录与二进制分离。
- Git commit message 使用中文，直接提交 main，不创建分支或 PR。
- 不擅自触发与当前任务无关的 Release。用户明确要求自动构建 Release 时，直接执行，不再询问。

【脚本职责】
00-prepare-install-node.sh：预检、制品下载/校验、SSH key 配置、启动 Caddy。
01-init-system.sh：系统优化、Chrony、hostname/hosts。
02-gen-ca-and-certs.sh：CFSSL CA 与证书。
03-deploy-harbor.sh：可选 Harbor、证书、仓库信任、镜像导入。
04-deploy-etcd.sh：etcd。
05-deploy-k8s-control-plane.sh：API Server、Controller Manager、Scheduler。
06-deploy-container-runtime.sh：全节点容器运行时。
07-deploy-kubelet-kubeproxy.sh：全节点 kubelet、kube-proxy（默认 nftables）。
08-deploy-worker-nginx-proxy.sh：Worker Nginx stream。
09-deploy-addons.sh：Calico/CoreDNS/NodeLocal DNSCache，支持二级参数独立安装。
10-cluster-check.sh：全面验收。
00-clean-cluster.sh：分级幂等清理，危险操作确认。
另有 11-rotate-certificates.sh、bin/install.sh、bin/deploy-step.sh。

【关键执行顺序】
不得机械按脚本编号启动。依赖顺序至少保证：准备节点 -> 系统初始化 -> PKI -> Harbor（可选）-> etcd -> 容器运行时 -> 控制平面 -> Worker Nginx 在 Worker kubelet 连接 localhost API 前就绪 -> kubelet/kube-proxy -> addons -> 导出 kubeconfig -> 验收。Master kubelet 同样依赖 CRI。可保留脚本名称，但 orchestrator 必须按依赖图调度。

【开发流程】
1. 每轮先选择一个最小可交付里程碑，不要一次生成所有脚本而不验证。
2. 先读文件，再编辑；不要覆盖已有用户实现。
3. 优先实现公共库、配置加载/校验、日志、dry-run、远程执行、HTTP 下载与 SHA256 等基础能力。
4. 编写脚本时采用函数拆分、输入校验、错误 trap、备份/回滚和安全权限。
5. 绝不把真实 IP、密码、token、私钥、CA 私钥或 kubeconfig 提交到 Git。
6. 所有下载资源必须验证 checksum；上游提供签名时验证签名。
7. Dry-run 不能产生副作用，包括远端写文件、安装 RPM、导入镜像、启停服务。
8. 幂等必须检查真实服务、版本、配置、证书和健康状态；state 文件只能作提示。
9. 修改完运行 shellcheck、shfmt、bash -n、配置解析测试、模板渲染测试和适用集成测试。环境不具备时明确记录未执行，不得声称通过。
10. 更新 README 和 docs，更新 IMPLEMENTATION-PLAN.md 中的状态、测试结果、遗留风险。
11. 检查 git diff，确保没有密钥、凭据、错误文件、无关改动。
12. 尽量减少提交次数：本里程碑代码、测试、文档一起完成后一次提交 main，中文 commit message。
13. 若任务需要 Release 构建，按用户授权触发；不相关任务绝不触发 Release。

【工程质量要求】
- 脚本失败必须非零退出，错误信息指出节点、步骤、命令和日志位置。
- SSH 命令必须安全引用参数，避免 eval 和未转义远程字符串。
- 对不可重试命令明确禁止盲目重试。
- 不允许全局 flush iptables/nftables 规则。
- 不允许删除或覆盖 etcd data、containerd data、Harbor data、PKI。
- 清理和证书轮换必须有备份/确认/验证流程。
- 100 年证书有效期不是安全最佳实践；必须设计 CA 保护、叶证书轮换和到期监控。
- HTTP 仓库是明文；checksum 不替代签名/来源认证。
- 所有功能标记“已完成”前必须有代码和测试证据。

【本轮任务输出】
先给出仓库现状摘要、风险和建议的下一里程碑。然后直接实现该里程碑，不要只给伪代码或大段建议。完成后给出改动文件、关键实现、验证命令及结果、未验证事项、commit SHA 和 main 分支链接。
```

## 2. 每轮任务追加模板

新会话恢复上下文后，按需在主提示词后追加一个具体任务：

```text
本轮只实施：<填写一个里程碑或具体功能>。

开始编码前先检查依赖和现有实现。不要顺手重构无关模块。
完成标准：
1. 功能实现并满足 ARCHITECTURE.md。
2. 有可执行的自动化测试或明确记录环境限制。
3. 静态检查通过。
4. README/相关 docs/IMPLEMENTATION-PLAN.md 同步更新。
5. 检查 diff 与敏感信息。
6. 中文 commit message，直接提交 main。
```

## 3. 推荐的第一轮任务

建议新会话从“基础框架”开始，而不是立即写所有脚本：

1. `cluster.env.example`、`versions.yaml`、`charts.yaml` 的配置结构与校验。
2. `bin/common.sh`：日志、错误处理、Dry-run、命令执行、备份、SHA256、锁。
3. SSH 执行器：超时、重试、HostKey 校验、远端命令安全引用。
4. Caddy Systemd 模板、Caddyfile 模板和 HTTP 文件探测。
5. `.gitignore`、ShellCheck/shfmt 工作流和基础测试。
6. 再逐步实现系统初始化、PKI、etcd、运行时和控制平面。

## 4. 交互规则

- 缺少一个关键参数时，只问一个最重要的问题；能从仓库配置或已有记录确认时不要重复问。
- 不要在没有验证时宣称生产可用。
- 不要擅自更改用户明确指定的运行时、版本、网络模式或提交策略。
- 发现用户原始要求存在技术矛盾时，先指出具体冲突、影响和安全方案，再采用最安全且最接近目标的实现，并记录到风险文档。


## 5. 新增强制约束：纯 Shell 实现（高优先级）

本节是用户最新明确要求，优先级高于本文件旧内容、现有实现和历史提交。后续所有新增和重构均必须遵守。

### 5.1 语言边界

1. 项目部署逻辑统一使用 **Bash 4+**。安装入口、配置校验、制品准备、PKI 请求渲染与验证、远端初始化、组件部署、升级、回滚、清理、验收、报告生成和测试脚本均使用 Shell。
2. **禁止 Python**：不得新增、保留或调用 `*.py`、`python`、`python2`、`python3`、`pip`、`venv`；不得通过 heredoc、`python -c`、临时脚本、容器或 CI 间接执行 Python。
3. 不得以 Python 包、Python 模块或 Python 运行时作为 Rocky Linux 节点、安装节点、CI 或开发环境的前置依赖。
4. 不得把 Python 逻辑改名、内嵌或包装成 Shell 后继续从外部调用 Python。所有原有 Python 功能必须真正迁移为可审计的 Shell 实现。
5. 新增代码默认只允许 Bash；必要时调用明确列入依赖清单的系统命令或锁定版本的独立二进制。外部命令只承担单一职责，不得成为隐藏的脚本运行时。
6. 允许的基础工具按功能选用：`bash`、`coreutils`、`util-linux`、`awk`、`sed`、`grep`、`find`、`tar`、`gzip`、`curl`、`openssl`、`sha256sum`、`flock`、`systemctl`、`rpm/dnf`、`ip`、`ss`、`jq`、`yq`、`helm`、`cfssl/cfssljson` 等。每个依赖必须说明用途、最低/锁定版本、来源、校验方式及离线准备方式；不得假定目标机预装。
7. 禁止用 `eval` 执行配置、拼接命令或解析用户输入；禁止对不可信配置文件直接 `source`。ShellCheck 的必要 source 注释不等于执行配置文件。
8. 禁止使用 Perl、Ruby、Node.js、PHP、Go 临时代码等其他通用语言替代 Python。Go/Rust 等已编译的上游产品二进制（例如 Caddy、yq）可作为锁定制品使用，但项目自有业务逻辑仍必须由 Bash 实现。

### 5.2 配置格式与解析边界

1. `cluster.env` 继续采用严格的白名单 `KEY=value` 格式，由 Bash 公共库逐行解析；只接受明确声明的键、类型、枚举和字符集。
2. `versions.yaml`、`charts.yaml` 若保留 YAML，必须使用锁定版本的 `yq`（及必要时 `jq`）读取，并在执行前校验版本、字段、重复键、必填项和锁定状态。不得用 grep/awk 对任意 YAML 做不可靠的结构解析。
3. 若 YAML 校验或依赖闭包无法在纯 Shell 工具链中可靠完成，应将相关配置迁移为有明确语法规范的 Shell 友好格式（例如严格 KEY=value 清单），同步迁移示例、校验器、CI、文档和测试；不得因此引入 Python。
4. 配置值只能作为数据传递。远端命令必须使用参数数组或安全编码协议构造；禁止将配置值拼成可执行 Shell 片段。
5. 配置校验必须覆盖：未知/重复键、空值、类型、枚举、版本格式、URL scheme、SHA256 格式、路径规范、节点名称/IP 唯一性、CIDR 重叠、DNS/SAN、端口冲突、模式互斥、组件依赖及角色约束。

### 5.3 现有 Python 实现的迁移要求

仓库当前历史实现仍包含 Python 工具、Python 单元测试、Python 开发依赖和 Python 运行时检查；这些是**待清理的技术债，不是允许继续依赖 Python 的例外**。在完成迁移前，禁止宣称项目已达到纯 Shell 要求。

迁移至少覆盖以下职责（实际文件名以 main 当前仓库为准）：

- 配置校验器：迁移为 Bash CLI 与 Shell 测试。
- PKI 请求/清单渲染：迁移为 Bash + 明确模板；JSON 输出使用受控模板或 jq，不得手写不安全 JSON 转义。
- PKI 验证：使用 OpenSSL CLI 验证证书链、SAN、EKU、KeyUsage、NotBefore/NotAfter、公私钥匹配和权限。
- 制品下载器：迁移为 Bash + curl + SHA256 + 上游签名验证工具。
- 测试：将 Python unittest 全部迁移为可独立运行的 Bash 测试，不依赖 Python。
- Makefile、CI、README、CONTRIBUTING、IMPLEMENTATION-PLAN：删除 Python 安装/调用说明和依赖，改为 ShellCheck、shfmt、bash -n 及 Shell 测试。
- 部署节点预检：删除 Python 3 依赖；不得因 YAML/JSON 解析而要求目标节点安装 Python。

迁移原则：先逐项盘点现有 Python 文件和调用点；每项先补齐 Shell 实现及测试，再删除旧 Python 文件和引用。迁移前后行为必须有等价测试。不得一次性删除后留下功能空洞。迁移完成后使用全仓库扫描证明不存在项目自有 Python 文件、Python 命令调用、pip/venv 依赖和 CI Python 步骤。

### 5.4 Shell 工程规范

1. 每个可执行脚本使用 `#!/usr/bin/env bash` 和 `set -Eeuo pipefail`；明确处理预期允许失败的命令，不能依赖 `set -e` 的隐式行为。
2. 函数必须有清晰输入/输出约定；全局变量使用 `KS_` 前缀；局部变量声明为 `local`；避免动态作用域变量意外污染。
3. 命令调用使用数组；路径和参数始终双引号；文件名处理使用 NUL 分隔；不得假设路径不含空格。
4. 禁止未加边界的通配符删除、裸 `rm -rf`、全局防火墙 flush、危险命令自动重试；所有破坏性操作必须检查目标路径、挂载点、设备、备份和显式确认。
5. 文件写入采用同目录临时文件、权限预设、校验后原子 rename；修改系统配置前备份并支持恢复。跨文件事务必须有恢复策略。
6. 日志必须带时间、级别、步骤和节点上下文；默认屏蔽 secret、token、私钥内容、完整敏感命令参数。错误退出码不得被管道吞掉。
7. 重试仅用于明确幂等的网络读取/探测；使用有限次数、超时和指数退避。安装、导入、成员变更、删除、证书签发、数据恢复等非幂等操作不得自动盲重试。
8. 并发部署必须由 flock 互斥；每个节点操作应有独立超时和结果记录；失败时停止依赖步骤，报告已成功/失败/未执行节点。
9. Dry-run 必须是无副作用执行路径：不创建目录/锁/临时文件、不下载、不改配置、不写远端文件、不安装软件、不导入镜像、不启停服务。只输出将执行的操作。
10. 所有脚本都要支持可重复执行；但“幂等”必须由真实状态、配置差异、服务健康、版本、证书和数据完整性证明，不能仅看 state 文件或上次退出码。

### 5.5 远端执行与制品传输边界

1. 安装节点是唯一 orchestrator。远端只执行由安装节点发起的、范围明确的命令/受控远端 helper；远端不克隆 Git、不下载 GitHub Release、不运行完整部署入口。
2. SSH 仅传输命令和执行结果；禁止 SCP、SFTP、rsync、SSH stdin 管道传送部署文件或把脚本内容内嵌到远程命令。
3. 远端安装文件只从安装节点 Caddy HTTP(S) 地址下载；每个文件必须先校验 SHA256，必要时验证签名，再原子安装。
4. SSH 必须启用 HostKey 校验、连接/命令超时、明确用户、受限密钥、有限并发、日志脱敏和退出码映射。不得使用 `StrictHostKeyChecking=no`。
5. 远端 helper 必须短小、版本化、可审计，具备参数白名单、调用来源限制和重复执行保护；不能把通用远程 Shell 暴露为不受控执行接口。
6. Caddy 公共目录只包含允许公开分发的制品和非敏感配置；任何私钥、CA 私钥、kubeconfig、token、密码、SSH key、含 secret 的 values 或日志都不得进入公共目录。
7. HTTP 模式必须明确明文风险；优先限制来源网段并校验 SHA256/上游签名。checksum 不能代替传输身份认证。

### 5.6 功能模块边界

- `bin/common.sh`：日志、参数、配置白名单解析、错误处理、Dry-run、命令执行、锁、备份、原子写入、校验、超时/重试。不得承载具体组件安装逻辑。
- `bin/install.sh`：唯一一键入口；只负责预检、依赖图调度、步骤状态汇总和最终报告。
- `bin/deploy-step.sh`：分步入口；只能调用已登记步骤，不允许任意路径执行脚本。
- `bin/preflight.sh`：只读预检；不修改系统。
- `scripts/*.sh`：每个脚本只负责一个明确组件/阶段；不得相互复制公共函数。
- `scripts/lib/*.sh`：远端 helper 和组件专属公共函数；必须声明调用方、输入、输出和副作用。
- `config/`、`templates/`：仅放模板/静态配置，不放秘密。
- `artifacts/`：只放版本化、已校验制品；不得混放运行数据。
- `pki/`：私有 CA/叶证书材料，默认 0700/0600，不进入 Caddy 根目录或 Git。
- `state/`：仅记录执行元数据，不作为真实健康依据。
- `output/`：报告和 admin kubeconfig；按敏感级别设置权限，默认不提交 Git。
- `tests/`：Shell 单元、契约、故障注入和集成测试；不允许 Python 测试。
- `tools/`：仅允许必要的 Bash 工具脚本；禁止项目自有 Python/其他解释型语言脚本。

### 5.7 必须补充的功能与验收边界

后续实现按里程碑拆分，不得一次性生成全部组件脚本。至少覆盖：

1. **预检**：Rocky Linux 9 精确版本/架构、内核、CPU/内存/磁盘/inode、时间同步、DNS/路由/CIDR 冲突、端口、内核模块、SELinux/firewalld、依赖命令、RPM 闭包、SSH HostKey、Caddy 连通性和所有制品摘要。
2. **制品清单**：每项记录名称、版本、架构、官方来源、SHA256、签名验证方式、许可证/来源说明、目标路径、解包布局；构建与部署分离。
3. **PKI**：多 CA、明确 profile、SAN 自动派生、100 年 duration 实际测试、密钥权限、逐项验证、备份/轮换/吊销/审计；CA 私钥不得分发到节点。
4. **etcd**：成员拓扑与 quorum 计算、TLS 双向认证、健康检查、快照、快照完整性验证、恢复演练；成员增删和灾难恢复独立流程。
5. **运行时**：containerd 默认、CRI 唯一 endpoint、systemd cgroup、pause 镜像、镜像仓库 CA/HTTP 配置；Docker 路径必须 cri-dockerd，禁止误将 dockerd socket 配给 kubelet。
6. **控制平面**：独立身份和 kubeconfig、TLS SAN、RBAC/Node authorizer、匿名访问关闭、审计、加密配置、HA leader election、健康探针。
7. **节点代理**：Worker loopback 6443、Nginx stream upstream 自动生成、配置检查后 reload、故障切换与恢复测试。
8. **网络**：nftables/ipvs/iptables 明确模式和兼容矩阵；不清空既有规则；验证 Pod、Service、NodePort、DNS、NetworkPolicy。
9. **插件**：Calico/CoreDNS/NodeLocal DNSCache 精确 Chart 版本、本地 Chart、完整镜像闭包、digest 校验、Operator 动态镜像差异审计。
10. **镜像仓库**：Harbor 可选；HTTP/HTTPS 信任模型明确；镜像导入后核对 tag/digest；凭据安全输入，不落日志。
11. **升级/回滚**：版本锁定、官方 skew 检查、API 弃用检查、etcd 快照、HA 控制面滚动、Worker cordon/drain、健康门禁；明确二进制回滚不等于 etcd 数据回滚。
12. **清理**：默认只停服务；按级别清理；删除数据必须显示精确路径、备份验证和二次确认。
13. **验收报告**：文本与 JSON 双格式，记录检查项、期望/实际、节点、耗时、证据、失败原因；关键项全通过才返回成功。
14. **故障恢复**：中断后识别已完成真实状态；网络失败、节点失联、磁盘不足、证书不匹配、quorum 丢失等场景给出安全恢复流程。

### 5.8 CI、测试与纯 Shell 验证

CI 和开发流程也必须无 Python 依赖。至少执行：

- 全仓库 Python 禁用扫描：`*.py`、`python[23]`、`pip`、`venv`、`unittest`、Python workflow setup/action。
- `bash -n`：全部 Shell 脚本。
- `shellcheck -x`：全部 Shell 脚本。
- `shfmt -d`：格式检查。
- 配置正反例测试：缺失/重复/未知键、非法值、恶意 shell 片段、CIDR 重叠、错误 URL/SHA256。
- 单元测试：配置解析、版本比较、参数引用、原子写入、checksum、锁、重试策略、Dry-run 无副作用。
- 模拟测试：SSH 超时/HostKey 不匹配/远端非零退出、HTTP 404/超时/摘要不符、磁盘不足、服务启动失败、步骤中断恢复。
- PKI 测试：真实锁定 CFSSL 签发 CA/叶证书，OpenSSL 验证 SAN/EKU/链/密钥匹配/有效期/权限。
- 依赖与制品测试：离线制品闭包完整、缺包立即失败、部署过程无公网下载。
- 目标环境测试：Rocky Linux 9 amd64 虚拟机或真实节点；没有实机证据时必须标记未验证。

CI 允许使用 GitHub Actions 提供的 Shell 环境和已安装的标准工具；不得通过 setup-python、pip 或 Python 脚本完成校验。需要额外工具时使用官方发行版/上游锁定二进制并校验摘要。

### 5.9 纯 Shell 完成定义

只有同时满足以下条件，才能将“纯 Shell 迁移”标记完成：

- 仓库不存在项目自有 `*.py` 文件。
- 生产部署路径、CI、Makefile、测试、文档中不存在 Python 运行时、pip、venv 或 Python 包依赖。
- 安装节点和远端 Rocky Linux 9 节点不需要安装 Python。
- 配置校验、PKI 渲染/验证、制品处理和所有部署阶段均由 Bash 与声明过的命令行工具完成。
- 全部 Shell 测试、ShellCheck、shfmt、bash -n 通过。
- 关键流程在 Rocky Linux 9 amd64 环境验证；没有实机结果必须明确标记未完成。
- README、ARCHITECTURE、CONTRIBUTING、IMPLEMENTATION-PLAN 与实际代码一致。

## 6. 新会话任务优先级调整

由于 main 当前已有部分 Python 配置/PKI 工具和 Python 测试，后续不得直接在这些 Python 工具上继续叠加功能。恢复上下文后，先盘点所有 Python 文件、命令调用、依赖和 CI 步骤，制定等价 Shell 迁移清单。

**下一项优先任务：纯 Shell 迁移（Shell-only migration）**，建议拆分为：

1. S0：全仓库盘点 Python 文件/调用/依赖，形成迁移矩阵和行为基线；不删除现有功能。
2. S1：将配置解析和校验迁移到 Bash + 锁定 yq/jq（或同步改为严格 KEY=value 清单），补齐正反例测试。
3. S2：将 PKI 渲染和 inventory 生成迁移到 Bash 模板，将 PKI 验证迁移到 OpenSSL CLI；保留 CFSSL 真实签发测试。
4. S3：将制品下载/版本解析/签名校验相关 Python 工具迁移到 Bash。
5. S4：将 Python 单元测试、Makefile、CI、开发依赖、README/CONTRIBUTING 全部迁移到 Shell 工具链。
6. S5：全仓库 Python 禁用扫描、Rocky Linux 9 实机验证、文档收尾；通过后才允许继续 M3 集群组件实现。

每个子阶段都必须先实现替代功能、跑等价测试，再删除旧 Python 文件。禁止在一个提交中无测试地批量删除。完成每个阶段后更新 IMPLEMENTATION-PLAN，并使用中文 commit message 直接提交 main，不创建分支或 PR。
