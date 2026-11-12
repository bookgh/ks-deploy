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
ks_config_load "$CONFIG_ENV"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    ks_die "安装节点要求 Linux amd64；当前为 $(uname -s)/$(uname -m)"
fi
os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
[[ "$os_id" == rocky && "${os_version%%.*}" == 9 ]] || ks_die "安装节点要求 Rocky Linux 9；当前为 ${os_id:-unknown} ${os_version:-unknown}"

for cmd in curl sha256sum tar cosign systemctl install useradd groupadd getent id awk; do
    command -v "$cmd" >/dev/null 2>&1 || ks_die "安装节点缺少命令：$cmd"
done
if [[ "$KS_DRY_RUN" != true && "$EUID" -ne 0 ]]; then
    ks_die "实际准备安装节点需要 root 权限"
fi

[[ -r "$CONFIG_VERSIONS" ]] || ks_die "找不到版本清单：$CONFIG_VERSIONS"
mapfile -t caddy_meta < <(awk '/^  caddy:$/ {inside=1; next} inside && /^  [^ ]/ {exit} inside && /^    / {sub(/^    [^:]+:[[:space:]]*/, ""); print}' "$CONFIG_VERSIONS")
((${#caddy_meta[@]} == 13)) || ks_die "无法读取 Caddy 锁定版本信息"
version="${caddy_meta[0]}"
archive_url="${caddy_meta[1]}"
archive_sha="${caddy_meta[2]}"
signature_url="${caddy_meta[3]}"
signature_sha="${caddy_meta[4]}"
certificate_url="${caddy_meta[5]}"
certificate_sha="${caddy_meta[6]}"
checksums_url="${caddy_meta[7]}"
checksums_sha="${caddy_meta[8]}"
checksums_signature_url="${caddy_meta[9]}"
checksums_signature_sha="${caddy_meta[10]}"
checksums_certificate_url="${caddy_meta[11]}"
checksums_certificate_sha="${caddy_meta[12]}"

caddy_root="$(ks_config_get CADDY_ROOT)"
artifacts_root="$(ks_config_get ARTIFACTS_ROOT)"
config_dir="$(ks_config_get CADDY_CONFIG_DIR)"
binary_root="$(ks_config_get CADDY_BIN_ROOT)"
caddy_bind="$(ks_config_get CADDY_BIND)"
caddy_port="$(ks_config_get CADDY_PORT)"
install_ip="$(ks_config_get INSTALL_NODE_IP)"
pki_dir="$(ks_config_get PKI_DIR)"
case "$ROOT/" in "$caddy_root/"*) ks_die "CADDY_ROOT 不得包含仓库目录" ;; esac
for protected_path in "$pki_dir" "$config_dir" "$ROOT/cluster.env" "$ROOT/pki" "$ROOT/output" "$ROOT/state" "$ROOT/secrets" "$ROOT/credentials"; do
    case "$protected_path/" in "$caddy_root/"*) ks_die "敏感路径不得位于 CADDY_ROOT 下：$protected_path" ;; esac
done

release_dir="$artifacts_root/bootstrap/caddy/$version"
archive="$release_dir/caddy.tar.gz"
signature="$release_dir/caddy.tar.gz.sig"
certificate="$release_dir/caddy.pem"
checksums="$release_dir/checksums.txt"
checksums_signature="$release_dir/checksums.txt.sig"
checksums_certificate="$release_dir/checksums.txt.pem"

ensure_asset() {
    local url="$1" digest="$2" file="$3"
    if [[ -f "$file" ]]; then
        ks_sha256_file "$file" "$digest"
    elif [[ "$(ks_config_get OFFLINE_MODE)" == true ]]; then
        ks_die "离线模式缺少已锁定制品：$file"
    else
        ks_http_download "$url" "$file" "$digest" 300 3
    fi
}

ensure_asset "$archive_url" "$archive_sha" "$archive"
ensure_asset "$signature_url" "$signature_sha" "$signature"
ensure_asset "$certificate_url" "$certificate_sha" "$certificate"
ensure_asset "$checksums_url" "$checksums_sha" "$checksums"
ensure_asset "$checksums_signature_url" "$checksums_signature_sha" "$checksums_signature"
ensure_asset "$checksums_certificate_url" "$checksums_certificate_sha" "$checksums_certificate"

if [[ "$KS_DRY_RUN" == true ]]; then
    ks_info "Dry-run：将验证 Caddy v$version 的 checksum 清单与两份 Sigstore 签名，并安装版本化二进制及 Caddy systemd 服务"
    exit 0
fi

identity="https://github.com/caddyserver/caddy/.github/workflows/release.yml@refs/tags/$version"
COSIGN_EXPERIMENTAL=1 cosign verify-blob --certificate "$checksums_certificate" --signature "$checksums_signature" --certificate-identity "$identity" --certificate-oidc-issuer https://token.actions.githubusercontent.com "$checksums"
COSIGN_EXPERIMENTAL=1 cosign verify-blob --certificate "$certificate" --signature "$signature" --certificate-identity "$identity" --certificate-oidc-issuer https://token.actions.githubusercontent.com "$archive"
expected_line="$(awk -v name="caddy_${version#v}_linux_amd64.tar.gz" '$2 == name {print $1}' "$checksums")"
[[ "$expected_line" == "$archive_sha" ]] || ks_die "签名 checksum 清单中的 Caddy tarball 哈希与 versions.yaml 不一致"

if tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.(\/|$)/ { bad=1 } END { if (bad || NR == 0) exit 1 }'; then
    :
else
    ks_die "Caddy archive 包含非法路径"
fi

version_dir="$binary_root/$version"
binary="$version_dir/caddy"
if [[ ! -x "$binary" ]]; then
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf -- "$tmp_dir"' EXIT
    tar -xzf "$archive" -C "$tmp_dir" --no-same-owner
    [[ -x "$tmp_dir/caddy" ]] || ks_die "Caddy archive 中未找到可执行 caddy"
    install -d -m 0755 "$version_dir"
    install -m 0755 "$tmp_dir/caddy" "$binary"
fi
"$binary" version | grep -Fq "$version" || ks_die "已安装 Caddy 二进制版本与锁定版本不符：$binary"

if ! getent group ks-deploy-http >/dev/null; then
    groupadd --system ks-deploy-http
fi
if ! id ks-deploy-http >/dev/null 2>&1; then
    useradd --system --gid ks-deploy-http --home-dir /var/lib/ks-deploy-caddy --no-create-home --shell /sbin/nologin ks-deploy-http
fi
install -d -o ks-deploy-http -g ks-deploy-http -m 0755 "$caddy_root"
chown -R ks-deploy-http:ks-deploy-http "$caddy_root"
find "$caddy_root" -type d -exec chmod 0755 {} +
find "$caddy_root" -type f -exec chmod 0644 {} +
install -d -o ks-deploy-http -g ks-deploy-http -m 0750 "$config_dir"

caddyfile="$config_dir/Caddyfile"
unit=/etc/systemd/system/ks-deploy-caddy.service
write_managed() {
    local destination="$1" mode="$2"
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    chmod "$mode" "$tmp"
    if [[ -f "$destination" ]] && cmp -s "$tmp" "$destination"; then
        rm -f "$tmp"
        return 1
    fi
    ks_backup_file "$destination"
    install -D -m "$mode" "$tmp" "$destination"
    rm -f "$tmp"
    return 0
}

changed=false
if write_managed "$caddyfile" 0640 <<EOF; then changed=true; fi
{
    admin 127.0.0.1:2019
}

http://$caddy_bind:$caddy_port {
    root * $caddy_root
    header X-Content-Type-Options nosniff
    header X-Frame-Options DENY
    file_server
}
EOF
if write_managed "$unit" 0644 <<EOF; then changed=true; fi
[Unit]
Description=ks-deploy artifact HTTP server (Caddy)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=ks-deploy-http
Group=ks-deploy-http
ExecStart=$binary run --environ --config $caddyfile
ExecReload=$binary reload --config $caddyfile --force
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitNPROC=4096
OOMScoreAdjust=-500
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadOnlyPaths=$caddy_root
StateDirectory=ks-deploy-caddy
StateDirectoryMode=0750

[Install]
WantedBy=multi-user.target
EOF
chown ks-deploy-http:ks-deploy-http "$caddyfile"

"$binary" validate --config "$caddyfile"
systemctl daemon-reload
systemctl enable ks-deploy-caddy.service
if systemctl is-active --quiet ks-deploy-caddy.service; then
    if [[ "$changed" == true ]]; then systemctl restart ks-deploy-caddy.service; fi
else
    systemctl start ks-deploy-caddy.service
fi
systemctl is-active --quiet ks-deploy-caddy.service || ks_die "Caddy 服务启动后未进入 active 状态"
http_code="$(curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 5 "http://$install_ip:$caddy_port/")"
[[ "$http_code" =~ ^(200|403|404)$ ]] || ks_die "Caddy HTTP 健康检查失败：HTTP $http_code"
ks_info "安装节点准备完成：Caddy v$version 正在 http://$install_ip:$caddy_port 提供制品"
