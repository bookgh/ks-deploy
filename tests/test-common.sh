#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() { printf 'PASS: %s\n' "$*"; }

cat >"$work/config" <<'EOF'
CLUSTER_NAME=ks-test
INSTALL_NODE_IP=192.0.2.2
EOF
ks_config_load "$work/config"
[[ "$(ks_config_get CLUSTER_NAME)" == ks-test ]] || fail '安全读取配置值'
pass '安全读取配置值'

printf "CLUSTER_NAME=\$(touch %s/pwned)\n" "$work" >"$work/config"
if ks_config_load "$work/config"; then fail '配置命令替换应失败'; fi
[[ ! -e "$work/pwned" ]] || fail '配置解析执行了命令'
pass '配置内容不执行 Shell 命令'

printf 'CLUSTER_NAME=first\nCLUSTER_NAME=second\n' >"$work/config"
if ks_config_load "$work/config"; then fail '重复键应失败'; fi
pass '重复配置键拒绝'

printf 'unknown\n' >"$work/config"
if ks_config_load "$work/config"; then fail '无等号配置应失败'; fi
pass '非法配置行拒绝'

printf abc >"$work/payload"
ks_sha256_file "$work/payload" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
if ks_sha256_file "$work/payload" 0000000000000000000000000000000000000000000000000000000000000000 2>/dev/null; then
    fail '错误 SHA256 应失败'
fi
if ks_ssh_exec 'invalid host' 1 5 /bin/true 2>/dev/null; then
    fail '非法 SSH 主机应失败'
fi
if ks_http_download file:///etc/passwd "$work/download" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 2>/dev/null; then
    fail '非 HTTP(S) URL 应失败'
fi
pass 'SHA256 正确匹配且拒绝不匹配'

KS_DRY_RUN=false
KS_LOCK_FILE="$work/state/deploy.lock"
ks_acquire_lock
[[ -f "$KS_LOCK_FILE" ]] || fail '互斥锁文件未创建'
if (
    KS_LOCK_FD=""
    ks_acquire_lock
) 2>/dev/null; then
    fail '并发部署应无法获取已持有的锁'
fi
pass '部署互斥锁拒绝并发执行'

KS_DRY_RUN=true
ks_run touch "$work/dry-run-marker" >/dev/null || fail 'Dry-run command wrapper failed'
ks_http_download https://example.invalid/payload "$work/download" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad >/dev/null 2>&1 || fail 'Dry-run HTTP wrapper failed'
ks_ssh_exec 192.0.2.10 1 5 /bin/true >/dev/null 2>&1 || fail 'Dry-run SSH wrapper failed'
KS_LOCK_FILE="$work/dry-run/lock"
ks_acquire_lock >/dev/null 2>&1 || fail 'Dry-run lock wrapper failed'
[[ ! -e "$work/dry-run-marker" && ! -e "$work/download" ]] || fail 'Dry-run 产生文件副作用'
[[ ! -e "$work/dry-run" ]] || fail 'Dry-run 创建锁文件或目录'
pass 'Dry-run 不写文件，且不调用 SSH/HTTP'

