#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/common.sh
source "$ROOT/bin/common.sh"
# shellcheck source=bin/pki.sh
source "$ROOT/bin/pki.sh"
# shellcheck source=bin/secret-transfer.sh
source "$ROOT/bin/secret-transfer.sh"
ks_init "$@"

CONFIG_ENV="${CONFIG_ENV:-$ROOT/cluster.env}"
CONFIG_VERSIONS="${CONFIG_VERSIONS:-$ROOT/versions.yaml}"
[[ -r "$CONFIG_ENV" && -r "$CONFIG_VERSIONS" ]] || ks_die "运行配置或版本锁定文件不可读"
ks_config_load "$CONFIG_ENV"

pki_dir="$(ks_config_get PKI_DIR)"; caddy_root="$(ks_config_get CADDY_ROOT)"
artifacts_root="$(ks_config_get ARTIFACTS_ROOT)"
[[ -n "$pki_dir" && -n "$caddy_root" && -n "$artifacts_root" ]] || ks_die "PKI_DIR、CADDY_ROOT、ARTIFACTS_ROOT 必须配置"
case "$pki_dir/" in "$caddy_root/"*) ks_die "PKI_DIR 不得位于 CADDY_ROOT 公共目录中" ;; esac
case "$caddy_root/" in "$pki_dir/"*) ks_die "CADDY_ROOT 不得位于 PKI_DIR 中" ;; esac
[[ "$pki_dir" != / && "${pki_dir##*/}" == pki && ! -L "$pki_dir" ]] || ks_die "PKI_DIR 必须是专用、非符号链接 pki 目录"

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
cfssl_version="$(yaml_component_field cfssl version)"; cfssljson_version="$(yaml_component_field cfssljson version)"
[[ "$cfssl_version" == "$cfssljson_version" ]] || ks_die "CFSSL 与 cfssljson 版本必须一致"
cfssl_url="$(yaml_component_field cfssl source_url)"; cfssl_sha="$(yaml_component_field cfssl sha256)"
cfssljson_url="$(yaml_component_field cfssljson source_url)"; cfssljson_sha="$(yaml_component_field cfssljson sha256)"
[[ "$cfssl_sha" =~ ^[a-f0-9]{64}$ && "$cfssljson_sha" =~ ^[a-f0-9]{64}$ ]] || ks_die "CFSSL 制品必须配置 SHA256"
[[ "$cfssl_url" == https://* && "$cfssljson_url" == https://* ]] || ks_die "CFSSL 制品来源必须使用 HTTPS"

if [[ "$KS_DRY_RUN" != true ]]; then
    [[ "$EUID" -eq 0 ]] || ks_die "证书生成必须在安装节点以 root 执行"
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || ks_die "证书生成要求 Linux amd64 安装节点"
fi
for cmd in openssl sha256sum date install cmp mktemp find grep stat awk curl; do command -v "$cmd" >/dev/null 2>&1 || ks_die "缺少命令：$cmd"; done

cfssl_root="$artifacts_root/bootstrap/cfssl/$cfssl_version"
cfssl_bin="$cfssl_root/cfssl"; cfssljson_bin="$cfssl_root/cfssljson"
ensure_binary() {
    local url="$1" digest="$2" path="$3"
    if [[ -f "$path" ]]; then ks_sha256_file "$path" "$digest"
    elif [[ "$(ks_config_get OFFLINE_MODE)" == true ]]; then ks_die "离线模式缺少 CFSSL 锁定制品：$path"
    else ks_http_download "$url" "$path" "$digest" 300 3; fi
    chmod 0755 "$path"; ks_sha256_file "$path" "$digest"
}
if [[ "$KS_DRY_RUN" != true ]]; then
    ensure_binary "$cfssl_url" "$cfssl_sha" "$cfssl_bin"
    ensure_binary "$cfssljson_url" "$cfssljson_sha" "$cfssljson_bin"
    "$cfssl_bin" version | grep -Eq "Version: v?${cfssl_version#v}([[:space:]]|$)" || ks_die "CFSSL 版本不匹配：$cfssl_version"
fi
if [[ "$KS_DRY_RUN" == true ]]; then
    ks_info "Dry-run：将使用纯 Bash 渲染并签发 PKI、验证 876000h 证书，再使用节点 RSA 公钥加密并通过 Caddy HTTP 分发；不会写文件、下载或连接节点"
    exit 0
fi

tmp_root="$(mktemp -d)"; staging_dir=""
cleanup() { rm -rf -- "$tmp_root"; [[ -z "$staging_dir" ]] || rm -rf -- "$staging_dir"; }
trap cleanup EXIT
spec_root="$tmp_root/specs"
ks_pki_render "$spec_root" "$(ks_config_get CLUSTER_NAME)" "$(ks_config_get MASTER_NODES)" "$(ks_config_get WORKER_NODES)" "$(ks_config_get SERVICE_CIDR)" "$(ks_config_get CLUSTER_DOMAIN)" "$(ks_config_get HARBOR_ENABLED)" "$(ks_config_get HARBOR_DOMAIN)"

distribute_pki() {
    local set role entry node address bundle
    for role in master worker; do
        if [[ "$role" == master ]]; then set="$(ks_config_get MASTER_NODES)"; else set="$(ks_config_get WORKER_NODES)"; fi
        IFS=',' read -r -a node_entries <<<"$set"
        for entry in "${node_entries[@]}"; do
            node="${entry%%=*}"; address="${entry#*=}"
            [[ "$node" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || ks_die "节点名称不合法，拒绝私钥分发：$node"
            bundle="$tmp_root/bundle-$node"
            ks_pki_bundle_for_node "$pki_dir" "$bundle" "$role" "$node"
            ks_secure_send "$address" "$node" "$bundle" "$pki_dir"
            rm -rf -- "$bundle"
        done
    done
}

verify_existing() {
    local expected actual relative
    [[ -f "$pki_dir/inventory.tsv" && -f "$pki_dir/ca-names.txt" ]] || ks_die "PKI inventory 缺失，拒绝覆盖：$pki_dir"
    while IFS= read -r -d '' expected; do
        relative="${expected#"$spec_root/"}"; actual="$pki_dir/$relative"
        [[ -f "$actual" ]] || ks_die "PKI 缺少配置/请求文件 $relative；拒绝覆盖"
        cmp -s "$expected" "$actual" || ks_die "PKI 请求配置不匹配：$relative；需走证书轮换流程"
    done < <(find "$spec_root" -type f -print0)
    ks_pki_verify "$pki_dir" $((876000*60*60))
}
if [[ -d "$pki_dir" ]] && [[ -n "$(find "$pki_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    verify_existing
    distribute_pki
    ks_info "现有 PKI 逐项验证并向全节点安全分发通过，未覆盖证书或私钥"
    exit 0
fi

pki_parent="$(dirname -- "$pki_dir")"; install -d "$pki_parent"
staging_dir="$(mktemp -d "$pki_parent/.ks-pki.XXXXXX")"; chmod 0700 "$staging_dir"
ks_pki_render "$staging_dir" "$(ks_config_get CLUSTER_NAME)" "$(ks_config_get MASTER_NODES)" "$(ks_config_get WORKER_NODES)" "$(ks_config_get SERVICE_CIDR)" "$(ks_config_get CLUSTER_DOMAIN)" "$(ks_config_get HARBOR_ENABLED)" "$(ks_config_get HARBOR_DOMAIN)"
while IFS= read -r ca_name; do
    ca_dir="$staging_dir/ca/$ca_name"
    "$cfssl_bin" gencert -initca -config "$ca_dir/ca-config.json" "$ca_dir/ca-csr.json" | "$cfssljson_bin" -bare "$ca_dir/ca"
    chmod 0644 "$ca_dir/ca.pem"; chmod 0600 "$ca_dir/ca-key.pem"
done <"$staging_dir/ca-names.txt"
install -d -m 0700 "$staging_dir/certs"
while IFS=$'\t' read -r name ca profile cn org ou hosts; do
    "$cfssl_bin" gencert -ca "$staging_dir/ca/$ca/ca.pem" -ca-key "$staging_dir/ca/$ca/ca-key.pem" \
        -config "$staging_dir/ca/$ca/ca-config.json" -profile "$profile" "$staging_dir/requests/$name.json" \
        | "$cfssljson_bin" -bare "$staging_dir/certs/$name"
    chmod 0644 "$staging_dir/certs/$name.pem"; chmod 0600 "$staging_dir/certs/$name-key.pem"; rm -f -- "$staging_dir/certs/$name.csr"
done <"$staging_dir/inventory.tsv"
install -d -m 0700 "$staging_dir/service-account"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$staging_dir/service-account/sa.key"
openssl pkey -in "$staging_dir/service-account/sa.key" -pubout -out "$staging_dir/service-account/sa.pub"
chmod 0600 "$staging_dir/service-account/sa.key"; chmod 0644 "$staging_dir/service-account/sa.pub"
ks_pki_verify "$staging_dir" $((876000*60*60))
for directory in "$staging_dir/ca" "$staging_dir/requests" "$staging_dir/certs" "$staging_dir/service-account"; do chmod 0700 "$directory"; done
chmod 0600 "$staging_dir/inventory.tsv" "$staging_dir/ca-names.txt"
if [[ -d "$pki_dir" ]]; then rmdir -- "$pki_dir" || ks_die "PKI_DIR 已变为非空，拒绝覆盖：$pki_dir"; fi
mv -- "$staging_dir" "$pki_dir"; staging_dir=""
ks_pki_verify "$pki_dir" $((876000*60*60))
distribute_pki
ks_info "PKI 首次生成并验证完成：$pki_dir；CA 私钥仅保留在安装节点，需离线备份"

