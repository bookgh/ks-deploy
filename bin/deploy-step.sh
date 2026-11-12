#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"

usage() {
    printf '用法：%s [--dry-run] STEP\n' "${0##*/}"
    printf 'STEP 可用项：prepare init pki harbor etcd runtime control-plane worker-proxy kubelet addons check\n'
}

step=""
init_args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) init_args+=(--dry-run) ;;
        *)
            if [[ -n "$step" ]]; then
                usage >&2
                exit 2
            fi
            step="$arg"
            ;;
    esac
done
[[ -n "$step" ]] || {
    usage >&2
    exit 2
}
ks_init "${init_args[@]}"
if [[ "${KS_LOCK_HELD:-false}" != true ]]; then
    ks_acquire_lock
fi

case "$step" in
    prepare) script=00-prepare-install-node.sh ;;
    init) script=01-init-system.sh ;;
    pki) script=02-gen-ca-and-certs.sh ;;
    harbor) script=03-deploy-harbor.sh ;;
    etcd) script=04-deploy-etcd.sh ;;
    control-plane) script=05-deploy-k8s-control-plane.sh ;;
    runtime) script=06-deploy-container-runtime.sh ;;
    kubelet) script=07-deploy-kubelet-kubeproxy.sh ;;
    worker-proxy) script=08-deploy-worker-nginx-proxy.sh ;;
    addons) script=09-deploy-addons.sh ;;
    check) script=10-cluster-check.sh ;;
    *)
        ks_die "未知部署步骤：$step"
        usage >&2
        exit 2
        ;;
esac

target="$ROOT/scripts/$script"
[[ -f "$target" ]] || ks_die "步骤尚未实现：$target"
if [[ "$KS_DRY_RUN" == true ]]; then
    exec bash "$target" --dry-run
fi
exec bash "$target"
