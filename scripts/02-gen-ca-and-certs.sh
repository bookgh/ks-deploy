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

pki_dir="$(ks_config_get PKI_DIR)"
caddy_root="$(ks_config_get CADDY_ROOT)"
artifacts_root="$(ks_config_get ARTIFACTS_ROOT)"
case "$pki_dir/" in "$caddy_root/"*) ks_die "PKI_DIR 不得位于 CADDY_ROOT 公共目录中" ;; esac
case "$caddy_root/" in "$pki_dir/"*) ks_die "CADDY_ROOT 不得位于 PKI_DIR 中" ;; esac
[[ "$pki_dir" != / && "${pki_dir##*/}" == pki ]] || ks_die "PKI_DIR 必须是专用 pki 目录且不得为 /：$pki_dir"
[[ ! -L "$pki_dir" ]] || ks_die "PKI_DIR 不得是符号链接：$pki_dir"
if [[ "$KS_DRY_RUN" != true ]]; then
    [[ "$EUID" -eq 0 ]] || ks_die "证书生成必须在安装节点以 root 执行"
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || ks_die "CFSSL 证书生成要求 Linux amd64 安装节点"
fi
for cmd in python3 openssl sha256sum date install cmp mktemp find grep stat; do
    command -v "$cmd" >/dev/null 2>&1 || ks_die "缺少命令：$cmd"
done

mapfile -t cfssl_meta < <(
    python3 - "$CONFIG_VERSIONS" <<'PY'
import sys
import yaml

components = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["components"]
for name in ("cfssl", "cfssljson"):
    item = components[name]
    print(item["version"])
    print(item["source_url"])
    print(item["sha256"])
PY
)
((${#cfssl_meta[@]} == 6)) || ks_die "无法读取锁定的 CFSSL/CFSSLJSON 制品"
[[ "${cfssl_meta[0]}" == "${cfssl_meta[3]}" ]] || ks_die "CFSSL 与 CFSSLJSON 版本必须一致"
version="${cfssl_meta[0]}"
cfssl_root="$artifacts_root/bootstrap/cfssl/$version"
cfssl_bin="$cfssl_root/cfssl"
cfssljson_bin="$cfssl_root/cfssljson"

ensure_binary() {
    local url="$1" digest="$2" path="$3"
    if [[ -f "$path" ]]; then
        ks_sha256_file "$path" "$digest"
    elif [[ "$(ks_config_get OFFLINE_MODE)" == true ]]; then
        ks_die "离线模式缺少 CFSSL 锁定制品：$path"
    else
        ks_http_download "$url" "$path" "$digest" 300 3
    fi
    chmod 0755 "$path"
    ks_sha256_file "$path" "$digest"
}

if [[ "$KS_DRY_RUN" != true ]]; then
    ensure_binary "${cfssl_meta[1]}" "${cfssl_meta[2]}" "$cfssl_bin"
    ensure_binary "${cfssl_meta[4]}" "${cfssl_meta[5]}" "$cfssljson_bin"
    "$cfssl_bin" version | grep -Eq "Version: v?${version#v}([[:space:]]|$)" || ks_die "CFSSL 版本不匹配：要求 $version"
fi

if [[ "$KS_DRY_RUN" == true ]]; then
    ks_info "Dry-run：将验证 CFSSL $version 制品与配置，生成 876000h（100×365 天）CA/叶证书，逐项校验 SAN、用途、证书链、公私钥配对和权限；不会创建或覆盖 PKI"
    exit 0
fi

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT
spec_root="$tmp_root/specs"
python3 "$ROOT/tools/render_pki.py" --env "$CONFIG_ENV" --output "$spec_root"

verify_existing() {
    local expected actual relative
    [[ -d "$pki_dir" ]] || return 1
    [[ -f "$pki_dir/inventory.json" ]] || ks_die "PKI 目录非空但缺少 inventory.json；拒绝覆盖：$pki_dir"
    while IFS= read -r -d '' expected; do
        relative="${expected#"$spec_root/"}"
        actual="$pki_dir/$relative"
        [[ -f "$actual" ]] || ks_die "PKI 缺少配置/请求文件 $relative；拒绝自动修复或覆盖"
        cmp -s "$expected" "$actual" || ks_die "PKI 请求配置与当前集群配置不一致：$relative；需要显式轮换流程"
    done < <(find "$spec_root" -type f -print0)
    python3 "$ROOT/tools/verify_pki.py" --pki-dir "$pki_dir"
    [[ "$(stat -c '%a' "$pki_dir")" == 700 ]] || ks_die "PKI 根目录权限必须为 0700"
    ks_info "现有 PKI 逐项验证通过，未覆盖任何证书或私钥"
}

if [[ -d "$pki_dir" ]] && [[ -n "$(find "$pki_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    verify_existing
    exit 0
fi

pki_parent="$(dirname -- "$pki_dir")"
install -d "$pki_parent"
staging_dir="$(mktemp -d "$pki_parent/.ks-pki.XXXXXX")"
chmod 0700 "$staging_dir"
trap 'rm -rf -- "$tmp_root"; [[ -z "${staging_dir:-}" ]] || rm -rf -- "$staging_dir"' EXIT
python3 "$ROOT/tools/render_pki.py" --env "$CONFIG_ENV" --output "$staging_dir"

for ca_name in $(python3 - "$staging_dir/inventory.json" <<'PY'
import json
import sys
print(" ".join(json.load(open(sys.argv[1], encoding="utf-8"))["certificate_authorities"]))
PY
); do
    ca_dir="$staging_dir/ca/$ca_name"
    "$cfssl_bin" gencert -initca -config "$ca_dir/ca-config.json" "$ca_dir/ca-csr.json" \
        | "$cfssljson_bin" -bare "$ca_dir/ca"
    chmod 0644 "$ca_dir/ca.pem"
    chmod 0600 "$ca_dir/ca-key.pem"
done

mkdir -m 0700 "$staging_dir/certs"
while IFS=$'\t' read -r name ca_name profile; do
    [[ -n "$name" ]] || continue
    ca_dir="$staging_dir/ca/$ca_name"
    "$cfssl_bin" gencert -ca "$ca_dir/ca.pem" -ca-key "$ca_dir/ca-key.pem" \
        -config "$ca_dir/ca-config.json" -profile "$profile" "$staging_dir/requests/$name.json" \
        | "$cfssljson_bin" -bare "$staging_dir/certs/$name"
    chmod 0644 "$staging_dir/certs/$name.pem"
    chmod 0600 "$staging_dir/certs/$name-key.pem"
    rm -f -- "$staging_dir/certs/$name.csr"
done < <(python3 - "$staging_dir/inventory.json" <<'PY'
import json
import sys
for item in json.load(open(sys.argv[1], encoding="utf-8"))["certificates"]:
    print(item["name"], item["ca"], item["profile"], sep="\t")
PY
)

mkdir -m 0700 "$staging_dir/service-account"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$staging_dir/service-account/sa.key"
openssl pkey -in "$staging_dir/service-account/sa.key" -pubout -out "$staging_dir/service-account/sa.pub"
chmod 0600 "$staging_dir/service-account/sa.key"
chmod 0644 "$staging_dir/service-account/sa.pub"
python3 "$ROOT/tools/verify_pki.py" --pki-dir "$staging_dir"

for directory in "$staging_dir/ca" "$staging_dir/requests" "$staging_dir/certs" "$staging_dir/service-account"; do
    chmod 0700 "$directory"
done
chmod 0600 "$staging_dir/inventory.json"
if [[ -d "$pki_dir" ]]; then
    rmdir -- "$pki_dir" || ks_die "PKI_DIR 已变为非空，拒绝覆盖：$pki_dir"
fi
mv -- "$staging_dir" "$pki_dir"
staging_dir=""
python3 "$ROOT/tools/verify_pki.py" --pki-dir "$pki_dir"
ks_info "PKI 首次生成并验证完成：$pki_dir；CA 私钥仅保留在安装节点，需离线备份"

