#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"
ks_init "$@"

CONFIG_ENV="${CONFIG_ENV:-$ROOT/cluster.env}"
CONFIG_VERSIONS="${CONFIG_VERSIONS:-$ROOT/versions.yaml}"
CONFIG_CHARTS="${CONFIG_CHARTS:-$ROOT/charts.yaml}"
[[ -r "$CONFIG_ENV" ]] || ks_die "找不到运行配置：$CONFIG_ENV"
python3 "$ROOT/tools/validate_config.py" --env "$CONFIG_ENV" --versions "$CONFIG_VERSIONS" --charts "$CONFIG_CHARTS"
ks_config_load "$CONFIG_ENV"

if [[ "$KS_DRY_RUN" != true && "$EUID" -ne 0 ]]; then
    ks_die "系统初始化必须从安装节点以 root 执行"
fi
for cmd in curl sha256sum python3 install; do
    command -v "$cmd" >/dev/null 2>&1 || ks_die "安装节点缺少命令：$cmd"
done

declare -a node_names=() node_ips=()
for node_set in "$(ks_config_get MASTER_NODES)" "$(ks_config_get WORKER_NODES)"; do
    IFS=',' read -r -a node_items <<<"$node_set"
    for node in "${node_items[@]}"; do
        node_names+=("${node%%=*}")
        node_ips+=("${node#*=}")
    done
done

install_ip="$(ks_config_get INSTALL_NODE_IP)"
caddy_port="$(ks_config_get CADDY_PORT)"
caddy_root="$(ks_config_get CADDY_ROOT)"
cluster="$(ks_config_get CLUSTER_NAME)"
stage_dir="$caddy_root/bootstrap/$cluster/system-init"
stage_url="http://$install_ip:$caddy_port/bootstrap/$cluster/system-init"
declare -A digests=()

render_assets() {
    local staging="$1" tmp index server
    install -d -m 0755 "$staging"
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' RETURN
    cat >"$tmp/10-ks-deploy.conf" <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_keepalive_time = 600
net.netfilter.nf_conntrack_max = 262144
EOF
    cat >"$tmp/10-ks-deploy.modules" <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
    cat >"$tmp/90-ks-deploy.limits" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65536
* hard nproc 65536
EOF
    : >"$tmp/ks-deploy.sources"
    IFS=',' read -r -a chrony_servers <<<"$(ks_config_get CHRONY_SERVERS)"
    for server in "${chrony_servers[@]}"; do
        printf 'server %s iburst\n' "$server" >>"$tmp/ks-deploy.sources"
    done
    : >"$tmp/hosts.block"
    for index in "${!node_names[@]}"; do
        printf '%s %s\n' "${node_ips[$index]}" "${node_names[$index]}" >>"$tmp/hosts.block"
    done
    for asset in 10-ks-deploy.conf 10-ks-deploy.modules 90-ks-deploy.limits ks-deploy.sources hosts.block; do
        local destination="$staging/$asset"
        if [[ ! -f "$destination" ]] || ! cmp -s "$tmp/$asset" "$destination"; then
            ks_backup_file "$destination"
            install -m 0644 "$tmp/$asset" "$destination"
        fi
        digests["$asset"]="$(sha256sum "$destination" | awk '{print $1}')"
    done
    chmod 0755 "$staging"
}

remote_script="$(<"$ROOT/scripts/lib/01-init-system-remote.sh")"

if [[ "$KS_DRY_RUN" == true ]]; then
    KS_TOTAL_STEPS="${#node_ips[@]}"
    for index in "${!node_ips[@]}"; do
        ks_progress "初始化节点 ${node_names[$index]} (${node_ips[$index]})"
        ks_ssh_exec "${node_ips[$index]}" 1 10 /bin/bash -c "$remote_script" ks-deploy "$stage_url" "${node_names[$index]}" "$(ks_config_get SELINUX_DISABLE)" "$(ks_config_get FIREWALLD_UNINSTALL)" "$(ks_config_get SWAP_DISABLE)" "dry-run"
    done
    exit 0
fi

render_assets "$stage_dir"
KS_TOTAL_STEPS="${#node_ips[@]}"
for index in "${!node_ips[@]}"; do
    ks_progress "初始化节点 ${node_names[$index]} (${node_ips[$index]})"
    args=("$stage_url")
    for asset in 10-ks-deploy.conf 10-ks-deploy.modules 90-ks-deploy.limits ks-deploy.sources hosts.block; do
        args+=("$asset" "${digests[$asset]}")
    done
    args+=("${node_names[$index]}" "$(ks_config_get SELINUX_DISABLE)" "$(ks_config_get FIREWALLD_UNINSTALL)" "$(ks_config_get SWAP_DISABLE)")
    ks_ssh_exec "${node_ips[$index]}" 2 10 /bin/bash -c "$remote_script" ks-deploy "${args[@]}"
done
ks_info "系统初始化已完成；SELinux 配置变更需要按主机状态重启后确认 Disabled。"

