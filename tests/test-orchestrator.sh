#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

if bash "$ROOT/bin/deploy-step.sh" unknown >/dev/null 2>&1; then
    fail '未知阶段必须返回非零状态'
fi
if bash "$ROOT/bin/deploy-step.sh" --dry-run prepare >/dev/null 2>&1; then
    fail '非 Rocky 9 环境或缺少 cosign 时必须明确失败'
fi
if bash "$ROOT/bin/install.sh" --dry-run >/dev/null 2>&1; then
    fail '缺失运行配置必须明确失败'
fi
sed "s#CADDY_ROOT=/srv/ks-deploy#CADDY_ROOT=$work/caddy#" "$ROOT/cluster.env.example" >"$work/cluster.env"
CONFIG_ENV="$work/cluster.env" bash "$ROOT/bin/deploy-step.sh" --dry-run init >/dev/null || fail '系统初始化 Dry-run 应成功'
[[ ! -e "$work/caddy" ]] || fail '系统初始化 Dry-run 不得创建 Caddy staging 文件'
printf 'PASS: 调度器拒绝未知阶段、未实现步骤和缺失配置；系统初始化 Dry-run 无副作用\n'

