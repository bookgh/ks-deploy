#!/usr/bin/env bash
set -euo pipefail

KS_DRY_RUN="false"
KS_TOTAL_STEPS="0"
KS_CURRENT_STEP="0"
KS_LOG_FILE=""
KS_LOCK_FD=""
declare -Ag KS_CONFIG=()

ks_init() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) KS_DRY_RUN=true ;;
            *) ks_die "未知参数：$arg" ;;
        esac
    done
    if [[ -z "$KS_LOG_FILE" ]]; then
        KS_LOG_FILE="${KS_LOG_FILE_OVERRIDE:-${TMPDIR:-/tmp}/ks-deploy-${USER:-unknown}.log}"
    fi
    trap 'ks_on_error "$?" "$BASH_COMMAND" "$LINENO"' ERR
}

ks_color() {
    [[ -t 2 && "${NO_COLOR:-}" == "" ]]
}

ks_log() {
    local level="$1"
    shift
    local line
    line="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [$level] $*"
    if ks_color; then
        case "$level" in
            ERROR) printf '\033[31m%s\033[0m\n' "$line" >&2 ;;
            WARN) printf '\033[33m%s\033[0m\n' "$line" >&2 ;;
            *) printf '\033[36m%s\033[0m\n' "$line" >&2 ;;
        esac
    else
        printf '%s\n' "$line" >&2
    fi
    if [[ "$KS_DRY_RUN" != true && -n "$KS_LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$KS_LOG_FILE" 2>/dev/null || true
    fi
}

ks_info() { ks_log INFO "$@"; }
ks_warn() { ks_log WARN "$@"; }
ks_die() {
    ks_log ERROR "$*"
    return 1
}

ks_on_error() {
    local status="$1" command="$2" line="$3"
    trap - ERR
    ks_log ERROR "步骤失败：${KS_CURRENT_STEP:-未编号}；命令：$command；行：$line；状态：$status；日志：$KS_LOG_FILE"
    exit "$status"
}

ks_progress() {
    local label="$1"
    KS_CURRENT_STEP=$((KS_CURRENT_STEP + 1))
    if ((KS_TOTAL_STEPS > 0)); then
        printf '[%02d/%02d] %s\n' "$KS_CURRENT_STEP" "$KS_TOTAL_STEPS" "$label"
    else
        printf '[%02d/??] %s\n' "$KS_CURRENT_STEP" "$label"
    fi
}

ks_config_load() {
    local file="$1" line key value line_no=0
    if [[ ! -r "$file" ]]; then
        ks_die "配置文件不可读：$file"
        return 1
    fi
    KS_CONFIG=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            ks_die "$file:$line_no：要求 KEY=value"
            return 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            ks_die "$file:$line_no：非法配置键：$key"
            return 1
        fi
        case "$key" in
            CLUSTER_NAME | INSTALL_NODE_IP | MASTER_NODES | WORKER_NODES | SSH_USER | SSH_PORT | CHRONY_SERVERS | CADDY_BIND | CADDY_PORT | CADDY_ROOT | CADDY_CONFIG_DIR | CADDY_BIN_ROOT | POD_CIDR | SERVICE_CIDR | CLUSTER_DNS | CLUSTER_DOMAIN | NODELOCAL_DNS_IP | CONTAINER_RUNTIME | PROXY_MODE | IMAGE_MODE | OFFLINE_MODE | HARBOR_ENABLED | HARBOR_NODE_IP | HARBOR_DOMAIN | HARBOR_SCHEME | HARBOR_PROJECT | SELINUX_DISABLE | FIREWALLD_UNINSTALL | SWAP_DISABLE | PKI_DIR | ARTIFACTS_ROOT | KUBELET_ROOT | CONTAINERD_ROOT | DOCKER_ROOT | ETCD_DATA_DIR | ETCD_BIN_ROOT | ETCD_CONFIG_DIR | ETCD_SNAPSHOT_DIR | ETCD_CLIENT_PORT | ETCD_PEER_PORT | ETCD_SNAPSHOT_HOUR) ;;
            *)
                ks_die "$file:$line_no：未知配置键：$key"
                return 1
                ;;
        esac
        # shellcheck disable=SC2016
        if [[ "$value" == *'$('* || "$value" == *'`'* || "$value" == *';'* ]]; then
            ks_die "$file:$line_no：配置值包含不允许的 Shell 语法"
            return 1
        fi
        if [[ -n "${KS_CONFIG[$key]+present}" ]]; then
            ks_die "$file:$line_no：重复配置键：$key"
            return 1
        fi
        KS_CONFIG["$key"]="$value"
    done <"$file"
}

ks_config_get() {
    local key="$1" default="${2:-}"
    if [[ -n "${KS_CONFIG[$key]+present}" ]]; then
        printf '%s' "${KS_CONFIG[$key]}"
    else
        printf '%s' "$default"
    fi
}

ks_run() {
    if [[ "$KS_DRY_RUN" == true ]]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

ks_sha256_file() {
    local file="$1" expected="$2" actual
    if [[ ! -f "$file" ]]; then
        ks_die "文件不存在：$file"
        return 1
    fi
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
        ks_die "SHA256 格式错误：$expected"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum -- "$file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 -- "$file" | awk '{print $1}')"
    else
        ks_die "缺少 sha256sum 或 shasum"
        return 1
    fi
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        ks_die "SHA256 不匹配：$file"
        return 1
    fi
}

ks_http_download() {
    local url="$1" destination="$2" expected="$3" timeout="${4:-120}" attempts="${5:-3}"
    if [[ ! "$timeout" =~ ^[1-9][0-9]*$ || "$timeout" -gt 3600 ]]; then
        ks_die "下载超时必须在 1 到 3600 秒之间"
        return 1
    fi
    if [[ ! "$attempts" =~ ^[1-5]$ ]]; then
        ks_die "下载重试次数必须在 1 到 5 次之间"
        return 1
    fi
    if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        ks_die "下载 URL 仅允许 HTTP(S)：$url"
        return 1
    fi
    if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
        ks_die "下载必须提供 SHA256"
        return 1
    fi
    if [[ "$KS_DRY_RUN" == true ]]; then
        ks_info "Dry-run：下载 $url -> $destination 并验证 SHA256"
        return 0
    fi
    local tmp attempt
    mkdir -p -- "$(dirname -- "$destination")"
    tmp="$(mktemp "${destination}.part.XXXXXX")"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if curl --proto '=http,https' --fail --location --silent --show-error --connect-timeout 10 --max-time "$timeout" --output "$tmp" "$url"; then
            if ks_sha256_file "$tmp" "$expected"; then
                chmod 0644 "$tmp"
                mv -f -- "$tmp" "$destination"
                return 0
            fi
            rm -f -- "$tmp"
            return 1
        fi
        ((attempt == attempts)) || sleep "$attempt"
    done
    rm -f -- "$tmp"
    ks_die "HTTP 下载失败（尝试 $attempts 次）：$url"
}

ks_ssh_exec() {
    local host="$1" retries="$2" connect_timeout="$3" command="" arg attempt
    local ssh_user="${KS_CONFIG[SSH_USER]:-${SSH_USER:-root}}"
    local ssh_port="${KS_CONFIG[SSH_PORT]:-${SSH_PORT:-22}}"
    shift 3
    if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        ks_die "SSH 主机名/IP 非法：$host"
        return 1
    fi
    if [[ ! "$retries" =~ ^[1-5]$ || ! "$connect_timeout" =~ ^[1-9][0-9]*$ || "$connect_timeout" -gt 300 ]]; then
        ks_die "SSH 重试次数必须为 1 到 5 次，连接超时须为 1 到 300 秒"
        return 1
    fi
    if [[ ! "$ssh_port" =~ ^[1-9][0-9]{0,4}$ || "$ssh_port" -gt 65535 ]]; then
        ks_die "SSH 端口非法"
        return 1
    fi
    if [[ ! "$ssh_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
        ks_die "SSH 用户名非法"
        return 1
    fi
    if (($# == 0)); then
        ks_die "SSH 命令不能为空"
        return 1
    fi
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        command+="${command:+ }$arg"
    done
    local -a opts=(-p "$ssh_port" -o "ConnectTimeout=$connect_timeout" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}" -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
    if [[ "$KS_DRY_RUN" == true ]]; then
        ks_info "Dry-run：ssh $ssh_user@$host <安全引用命令>"
        return 0
    fi
    for ((attempt = 1; attempt <= retries; attempt++)); do
        if timeout --foreground "${SSH_COMMAND_TIMEOUT:-300}" ssh "${opts[@]}" "$ssh_user@$host" "$command"; then
            return 0
        else
            ((attempt == retries)) || sleep "$attempt"
        fi
    done
    ks_die "SSH 失败：节点 $host，命令 $*，重试 $retries 次；日志 $KS_LOG_FILE"
}

ks_backup_file() {
    local file="$1" backup
    [[ -e "$file" ]] || return 0
    backup="${file}.bak.$(date -u +'%Y%m%dT%H%M%SZ')"
    if [[ "$KS_DRY_RUN" == true ]]; then
        ks_info "Dry-run：备份 $file -> $backup"
        return 0
    fi
    cp -a -- "$file" "$backup"
    ks_info "已备份：$backup"
}

ks_acquire_lock() {
    local lock_file="${1:-${KS_LOCK_FILE:-${TMPDIR:-/tmp}/ks-deploy.lock}}"
    if [[ "$KS_DRY_RUN" == true ]]; then
        ks_info "Dry-run：跳过部署互斥锁 $lock_file"
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        ks_die "缺少 flock，无法保证部署互斥"
        return 1
    }
    install -d -m 0700 -- "$(dirname -- "$lock_file")"
    [[ ! -L "$lock_file" ]] || {
        ks_die "拒绝跟随锁文件符号链接：$lock_file"
        return 1
    }
    exec {KS_LOCK_FD}>>"$lock_file"
    chmod 0600 -- "$lock_file"
    if ! flock -n "$KS_LOCK_FD"; then
        ks_die "已有部署流程持有锁：$lock_file"
        return 1
    fi
    ks_info "已获得部署互斥锁：$lock_file"
}

