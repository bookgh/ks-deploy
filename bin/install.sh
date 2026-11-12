#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"
ks_init "$@"

CONFIG_ENV="${CONFIG_ENV:-$ROOT/cluster.env}"
CONFIG_VERSIONS="${CONFIG_VERSIONS:-$ROOT/versions.yaml}"
CONFIG_CHARTS="${CONFIG_CHARTS:-$ROOT/charts.yaml}"

[[ -r "$CONFIG_ENV" ]] || ks_die "找不到运行配置：$CONFIG_ENV（请从 cluster.env.example 复制）"
python3 "$ROOT/tools/validate_config.py" --env "$CONFIG_ENV" --versions "$CONFIG_VERSIONS" --charts "$CONFIG_CHARTS"
ks_config_load "$CONFIG_ENV"

# 依赖顺序与脚本编号不同：Master CRI 在控制面前，Worker API 代理在 kubelet 前。
steps=(prepare init pki harbor etcd runtime control-plane worker-proxy kubelet addons check)
KS_TOTAL_STEPS="${#steps[@]}"
for step in "${steps[@]}"; do
    if [[ "$step" == harbor && "$(ks_config_get HARBOR_ENABLED)" != true ]]; then
        ks_progress "跳过可选 Harbor"
        continue
    fi
    ks_progress "运行阶段：$step"
    if [[ "$KS_DRY_RUN" == true ]]; then
        bash "$ROOT/bin/deploy-step.sh" --dry-run "$step"
    else
        bash "$ROOT/bin/deploy-step.sh" "$step"
    fi
done
