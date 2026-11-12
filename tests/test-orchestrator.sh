#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

if bash "$ROOT/bin/deploy-step.sh" unknown >/dev/null 2>&1; then
    fail '未知阶段必须返回非零状态'
fi
if bash "$ROOT/bin/deploy-step.sh" --dry-run prepare >/dev/null 2>&1; then
    fail '未实现的阶段必须明确失败'
fi
if bash "$ROOT/bin/install.sh" --dry-run >/dev/null 2>&1; then
    fail '缺失运行配置必须明确失败'
fi
printf 'PASS: 调度器拒绝未知阶段、未实现步骤和缺失配置\n'
