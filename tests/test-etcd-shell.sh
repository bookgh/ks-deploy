#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
node_script="$ROOT/scripts/lib/04-etcd-node.sh"
deploy_script="$ROOT/scripts/04-deploy-etcd.sh"

[[ -x "$node_script" || -f "$node_script" ]]
[[ -f "$deploy_script" ]]
bash -n "$node_script" "$deploy_script"

if grep -nEi 'python(3)?|scp|rsync|eval[[:space:]]' "$node_script" "$deploy_script"; then
    printf 'FAIL: etcd deployment scripts contain a prohibited runtime or transfer method\n' >&2
    exit 1
fi

for required in \
    'sha256sum --check' \
    'initial-cluster-state: new' \
    'client-cert-auth: true' \
    'peer-transport-security:' \
    'LimitNOFILE=' \
    'LimitNPROC=' \
    'OOMScoreAdjust=' \
    'endpoint health' \
    'snapshot save' \
    'systemctl enable etcd.service etcd-snapshot.timer'; do
    grep -Fq -- "$required" "$node_script" || {
        printf 'FAIL: missing etcd node invariant: %s\n' "$required" >&2
        exit 1
    }
done

grep -Fq 'if [[ "$KS_DRY_RUN" == true ]]; then' "$deploy_script"
grep -Fq 'ensure_archive' "$deploy_script"
grep -Fq 'etcd) script=04-deploy-etcd.sh' "$ROOT/bin/deploy-step.sh"
printf 'PASS: etcd deployment shell policy and safety invariants\n'
