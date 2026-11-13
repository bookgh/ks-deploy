#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"
ks_init "$@"

CONFIG_ENV="${CONFIG_ENV:-$ROOT/cluster.env}"
CONFIG_VERSIONS="${CONFIG_VERSIONS:-$ROOT/versions.yaml}"
[[ -r "$CONFIG_ENV" && -r "$CONFIG_VERSIONS" ]] || ks_die "运行配置或版本锁定文件不可读"
ks_config_load "$CONFIG_ENV"

yaml_component_field() {
    local component="$1" field="$2"
    awk -v component="$component" -v field="$field" '
      $0 == "  " component ":" { inside=1; next }
      inside && /^  [^ ]/ { inside=0 }
      inside && $0 ~ "^    " field ":[[:space:]]*" {
        sub("^    " field ":[[:space:]]*", ""); print; found=1; exit
      }
      END { if (!found) exit 1 }
    ' "$CONFIG_VERSIONS"
}

version="$(yaml_component_field etcd version)"
archive_source="$(yaml_component_field etcd source_url)"
archive_sha="$(yaml_component_field etcd sha256)"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ks_die "etcd 版本必须为精确版本号"
[[ "$archive_source" == "https://github.com/etcd-io/etcd/releases/download/$version/etcd-$version-linux-amd64.tar.gz" ]] || ks_die "etcd 制品必须来自对应官方 GitHub Release"
[[ "$archive_sha" =~ ^[a-f0-9]{64}$ ]] || ks_die "etcd 制品必须锁定 SHA256"

masters="$(ks_config_get MASTER_NODES)"
cluster="$(ks_config_get CLUSTER_NAME)"
install_ip="$(ks_config_get INSTALL_NODE_IP)"
caddy_port="$(ks_config_get CADDY_PORT)"
caddy_root="$(ks_config_get CADDY_ROOT)"
artifacts_root="$(ks_config_get ARTIFACTS_ROOT)"
pki_dir="$(ks_config_get PKI_DIR)"
bin_root="$(ks_config_get ETCD_BIN_ROOT)"
data_dir="$(ks_config_get ETCD_DATA_DIR)"
config_dir="$(ks_config_get ETCD_CONFIG_DIR)"
snapshot_dir="$(ks_config_get ETCD_SNAPSHOT_DIR)"
client_port="$(ks_config_get ETCD_CLIENT_PORT)"
peer_port="$(ks_config_get ETCD_PEER_PORT)"
snapshot_hour="$(ks_config_get ETCD_SNAPSHOT_HOUR)"
for value in "$masters" "$cluster" "$install_ip" "$caddy_port" "$caddy_root" "$artifacts_root" "$pki_dir" "$bin_root" "$data_dir" "$config_dir" "$snapshot_dir" "$client_port" "$peer_port" "$snapshot_hour"; do
    [[ -n "$value" ]] || ks_die "etcd 所需配置项存在空值"
done
[[ ! "$pki_dir/" == "$caddy_root/"* && ! "$caddy_root/" == "$pki_dir/"* ]] || ks_die "PKI_DIR 与 CADDY_ROOT 不得重叠"
paths_overlap() { [[ "$1/" == "$2/"* || "$2/" == "$1/"* ]]; }
for left in "$data_dir" "$bin_root" "$config_dir" "$snapshot_dir"; do
    for right in "$data_dir" "$bin_root" "$config_dir" "$snapshot_dir"; do
        [[ "$left" == "$right" ]] && continue
        paths_overlap "$left" "$right" && ks_die "etcd 数据、二进制、配置和快照目录不得相互重叠：$left / $right"
    done
done

archive="$artifacts_root/bootstrap/etcd/$version/etcd.tar.gz"
caddy_asset="$caddy_root/bootstrap/etcd/$version/etcd.tar.gz"
asset_url="http://$install_ip:$caddy_port/bootstrap/etcd/$version/etcd.tar.gz"
ensure_archive() {
    if [[ -f "$archive" ]]; then
        ks_sha256_file "$archive" "$archive_sha"
    elif [[ "$(ks_config_get OFFLINE_MODE)" == true ]]; then
        ks_die "离线模式缺少锁定的 etcd 制品：$archive"
    else
        ks_http_download "$archive_source" "$archive" "$archive_sha" 300 3
    fi
    install -d -m 0755 "$(dirname -- "$caddy_asset")"
    if [[ -f "$caddy_asset" ]]; then
        ks_sha256_file "$caddy_asset" "$archive_sha"
    else
        install -m 0644 "$archive" "$caddy_asset"
    fi
    ks_sha256_file "$caddy_asset" "$archive_sha"
}

remote_script="$(<"$ROOT/scripts/lib/04-etcd-node.sh")"
declare -a node_names=() node_ips=()
IFS=',' read -r -a entries <<<"$masters"
for entry in "${entries[@]}"; do
    node_names+=("${entry%%=*}")
    node_ips+=("${entry#*=}")
done
if [[ "$KS_DRY_RUN" == true ]]; then
    ks_progress "检查锁定 etcd $version 并部署 Master etcd/TLS/systemd/snapshot timer"
else
    ensure_archive
fi
KS_TOTAL_STEPS=$(( ${#node_names[@]} * 3 ))
for index in "${!node_names[@]}"; do
    node="${node_names[$index]}"; ip="${node_ips[$index]}"
    ks_progress "准备 Master $node 的 etcd $version、mTLS 与定时快照"
    ks_ssh_exec "$ip" 2 20 /bin/bash -c "$remote_script" ks-etcd prepare \
        "$version" "$asset_url" "$archive_sha" "$node" "$ip" "$masters" "$cluster" \
        "$bin_root" "$data_dir" "$config_dir" "$snapshot_dir" "$client_port" "$peer_port" \
        "$snapshot_hour" "$pki_dir"
done
for index in "${!node_names[@]}"; do
    node="${node_names[$index]}"; ip="${node_ips[$index]}"
    ks_progress "启动 Master $node etcd"
    ks_ssh_exec "$ip" 2 20 /bin/bash -c "$remote_script" ks-etcd start \
        "$version" "$asset_url" "$archive_sha" "$node" "$ip" "$masters" "$cluster" \
        "$bin_root" "$data_dir" "$config_dir" "$snapshot_dir" "$client_port" "$peer_port" \
        "$snapshot_hour" "$pki_dir"
done
for index in "${!node_names[@]}"; do
    node="${node_names[$index]}"; ip="${node_ips[$index]}"
    ks_progress "验证 Master $node etcd health/member/snapshot"
    ks_ssh_exec "$ip" 2 20 /bin/bash -c "$remote_script" ks-etcd check \
        "$version" "$asset_url" "$archive_sha" "$node" "$ip" "$masters" "$cluster" \
        "$bin_root" "$data_dir" "$config_dir" "$snapshot_dir" "$client_port" "$peer_port" \
        "$snapshot_hour" "$pki_dir"
done
ks_info "etcd $version 已在全部 Master 节点运行并通过 mTLS health/member/snapshot 检查；数据目录未清理或覆盖"
