#!/usr/bin/env bash
set -euo pipefail

script_dir=$(dirname -- "${BASH_SOURCE[0]}")
repo_root=$(cd -- "$script_dir/.." && pwd) || exit 1
python_bin=${PYTHON:-python3}
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

"$python_bin" "$repo_root/tools/validate_config.py" \
    --env "$repo_root/cluster.env.example" \
    --versions "$repo_root/versions.yaml" \
    --charts "$repo_root/charts.yaml"

sed 's/^  version: v1\.37\.2$/  version: ""/' \
    "$repo_root/versions.yaml" >"$tmp_dir/versions-invalid.yaml"
if "$python_bin" "$repo_root/tools/validate_config.py" \
    --env "$repo_root/cluster.env.example" \
    --versions "$tmp_dir/versions-invalid.yaml" \
    --charts "$repo_root/charts.yaml"; then
    echo '错误：空 Kubernetes 版本未被校验器拒绝' >&2
    exit 1
fi

printf '%s\n' '配置校验器 CLI 正反向 smoke test 通过'
