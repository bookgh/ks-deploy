#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
shift || true
version="$1" archive_url="$2" archive_sha="$3" node="$4" node_ip="$5"
masters="$6" cluster="$7" bin_root="$8" data_dir="$9"
config_dir="${10}" snapshot_dir="${11}" client_port="${12}" peer_port="${13}"
snapshot_hour="${14}" pki_root="${15}"

die() { printf 'etcd 节点步骤失败：%s\n' "$*" >&2; exit 1; }
is_ipv4() {
    local address="$1" octet
    [[ "$address" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do [[ "$octet" -le 255 ]] || return 1; done
}
[[ "$(id -u)" == 0 ]] || die "必须以 root 执行"
source /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID%%.*}" == 9 && "$(uname -m)" == x86_64 ]] || die "目标系统必须为 Rocky Linux 9 amd64"
[[ "$node" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "节点名称非法"
[[ "$cluster" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "集群名称非法"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "etcd 版本非法"
is_ipv4 "$node_ip" || die "节点 IPv4 非法：$node_ip"
[[ "$archive_sha" =~ ^[a-f0-9]{64}$ ]] || die "etcd archive SHA256 非法"
for path in "$bin_root" "$data_dir" "$config_dir" "$snapshot_dir" "$pki_root"; do
    [[ "$path" == /* && "$path" != *..* && "$path" != *[[:space:]]* ]] || die "路径不安全：$path"
done
[[ "$client_port" =~ ^[1-9][0-9]{0,4}$ && "$client_port" -le 65535 ]] || die "ETCD client 端口非法"
[[ "$peer_port" =~ ^[1-9][0-9]{0,4}$ && "$peer_port" -le 65535 && "$peer_port" != "$client_port" ]] || die "ETCD peer 端口非法"
[[ "$snapshot_hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "快照时间非法"
[[ "$archive_url" =~ ^http://[A-Za-z0-9._:-]+/[A-Za-z0-9._/-]+$ ]] || die "制品 URL 非法"
[[ "$masters" != *".."* && "$masters" != *[[:space:]]* ]] || die "Master 列表非法"
[[ "$action" == prepare || "$action" == start || "$action" == check ]] || die "未知 action：$action"
IFS=',' read -r -a master_entries <<<"$masters"
(( ${#master_entries[@]} > 0 )) || die "Master 列表不能为空"
paths_overlap() { [[ "$1/" == "$2/"* || "$2/" == "$1/"* ]]; }
for left in "$data_dir" "$bin_root" "$config_dir" "$snapshot_dir" "$pki_root"; do
    [[ "$left" != / ]] || die "etcd 路径不得指向文件系统根目录"
    for right in "$data_dir" "$bin_root" "$config_dir" "$snapshot_dir" "$pki_root"; do
        [[ "$left" == "$right" ]] && continue
        paths_overlap "$left" "$right" && die "etcd 数据、二进制、配置、快照和 PKI 路径不得重叠：$left / $right"
    done
done

for command in curl sha256sum tar install cmp cp stat find awk sed date systemctl getent useradd groupadd id openssl chown; do
    command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
done

etcd_name="etcd.service"
config_file="$config_dir/etcd.yaml"
unit_file="/etc/systemd/system/$etcd_name"
snapshot_service="/etc/systemd/system/etcd-snapshot.service"
snapshot_timer="/etc/systemd/system/etcd-snapshot.timer"
etcd_bin="$bin_root/$version/etcd"
etcdctl_bin="$bin_root/$version/etcdctl"
etcdutl_bin="$bin_root/$version/etcdutl"
private_dir="$config_dir/pki/private"
cert_dir="$config_dir/pki"
node_pki="$pki_root/$node"
if [[ "$action" == prepare ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    curl --proto '=http,https' --fail --location --silent --show-error --connect-timeout 10 --max-time 300 --output "$work/etcd.tar.gz" "$archive_url"
    printf '%s  %s\n' "$archive_sha" "$work/etcd.tar.gz" | sha256sum --check --status || die "节点 $node etcd 制品 SHA256 校验失败"
    tar -tzf "$work/etcd.tar.gz" | awk '/^\// || /(^|\/)\.\.(\/|$)/ {bad=1} END {if (bad || NR==0) exit 1}' || die "etcd archive 路径非法"
    tar -tvzf "$work/etcd.tar.gz" | awk 'substr($1,1,1)!="-" && substr($1,1,1)!="d" {bad=1} END {exit bad}' || die "拒绝含链接或特殊文件的 etcd archive"
    mkdir -m 0700 "$work/unpack"
    tar -xzf "$work/etcd.tar.gz" --no-same-owner -C "$work/unpack"
    source_etcd="$(find "$work/unpack" -type f -name etcd -print -quit)"
    source_etcdctl="$(find "$work/unpack" -type f -name etcdctl -print -quit)"
    source_etcdutl="$(find "$work/unpack" -type f -name etcdutl -print -quit)"
    [[ -x "$source_etcd" && -x "$source_etcdctl" && -x "$source_etcdutl" ]] || die "官方 archive 缺少 etcd/etcdctl/etcdutl"
    install -d -m 0755 "$bin_root/$version"
    for name in etcd etcdctl etcdutl; do
        source_path="$work/unpack/$(find "$work/unpack" -type f -name "$name" -printf '%P\n' -quit)"
        destination="$bin_root/$version/$name"
        if [[ -e "$destination" ]]; then
            [[ -x "$destination" ]] || die "现有版本化二进制不可执行：$destination"
            cmp -s "$source_path" "$destination" || die "版本目录存在内容不一致的 $name，拒绝覆盖：$destination"
        else
            install -m 0755 "$source_path" "$destination"
        fi
    done
    "$etcd_bin" --version | grep -Fq "etcd Version: ${version#v}" || die "etcd 二进制版本不匹配"
    "$etcdctl_bin" version | grep -Fq "etcdctl version: ${version#v}" || die "etcdctl 二进制版本不匹配"

    for file in ca/etcd/ca.pem certs/etcd-server-"$node".pem certs/etcd-server-"$node"-key.pem certs/etcd-peer-"$node".pem certs/etcd-peer-"$node"-key.pem certs/apiserver-etcd-client.pem certs/apiserver-etcd-client-key.pem; do
        [[ -s "$node_pki/$file" ]] || die "节点 $node 缺少 etcd TLS 文件：$node_pki/$file"
    done
    for file in certs/etcd-server-"$node"-key.pem certs/etcd-peer-"$node"-key.pem certs/apiserver-etcd-client-key.pem; do
        [[ "$(stat -c '%a' "$node_pki/$file")" == 600 ]] || die "私钥权限错误：$node_pki/$file"
    done
    if ! getent group etcd >/dev/null; then groupadd --system etcd; fi
    if ! id etcd >/dev/null 2>&1; then useradd --system --gid etcd --home-dir /var/lib/etcd --no-create-home --shell /sbin/nologin etcd; fi
    if [[ ! -e "$data_dir" ]]; then
        install -d -o etcd -g etcd -m 0700 "$data_dir"
    else
        [[ -d "$data_dir" && ! -L "$data_dir" ]] || die "拒绝使用非目录或符号链接 etcd 数据路径：$data_dir"
        if [[ -n "$(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            [[ "$(stat -c '%U:%G' "$data_dir")" == etcd:etcd ]] || die "现有 etcd 数据目录 owner 不是 etcd:etcd；拒绝递归 chown：$data_dir"
        else
            chown etcd:etcd "$data_dir"
            chmod 0700 "$data_dir"
        fi
    fi
    install -d -o root -g etcd -m 0750 "$config_dir" "$cert_dir"
    install -d -o etcd -g etcd -m 0700 "$private_dir"
    if [[ -e "$snapshot_dir" ]]; then
        [[ -d "$snapshot_dir" && ! -L "$snapshot_dir" ]] || die "快照目录不是安全目录：$snapshot_dir"
        if [[ -n "$(find "$snapshot_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            [[ "$(stat -c '%U:%G' "$snapshot_dir")" == etcd:etcd ]] || die "快照目录 owner 不是 etcd:etcd；拒绝修改已有内容"
        else
            chown etcd:etcd "$snapshot_dir"; chmod 0700 "$snapshot_dir"
        fi
    else
        install -d -o etcd -g etcd -m 0700 "$snapshot_dir"
    fi

    write_managed() {
        local destination="$1" mode="$2" owner="$3" group="$4" temp="$work/rendered"
        cat >"$temp"
        chmod "$mode" "$temp"
        if [[ -f "$destination" ]] && cmp -s "$temp" "$destination"; then return 1; fi
        if systemctl is-active --quiet "$etcd_name"; then die "etcd 正在运行且配置需要改变；请执行显式滚动变更，拒绝自动重启/覆盖"
        fi
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" ]] || die "拒绝覆盖非普通文件：$destination"
            cp -a "$destination" "$destination.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        fi
        install -D -o "$owner" -g "$group" -m "$mode" "$temp" "$destination"
        return 0
    }
    changed=false
    for file in ca/etcd/ca.pem certs/etcd-server-"$node".pem certs/etcd-peer-"$node".pem certs/apiserver-etcd-client.pem; do
        basename="${file##*/}"
        if write_managed "$cert_dir/$basename" 0640 root etcd <"$node_pki/$file"; then changed=true; fi
    done
    for file in certs/etcd-server-"$node"-key.pem certs/etcd-peer-"$node"-key.pem certs/apiserver-etcd-client-key.pem; do
        basename="${file##*/}"
        destination="$private_dir/${basename%-key.pem}.key"
        if write_managed "$destination" 0600 etcd etcd <"$node_pki/$file"; then changed=true; fi
    done

    initial_cluster=""
    for entry in "${master_entries[@]}"; do
        master_name="${entry%%=*}"; master_ip="${entry#*=}"
        [[ "$master_name" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] && is_ipv4 "$master_ip" || die "Master 地址格式错误：$entry"
        initial_cluster+="${initial_cluster:+,}$master_name=https://$master_ip:$peer_port"
    done
    listen_clients="https://127.0.0.1:$client_port,https://$node_ip:$client_port"
    if write_managed "$config_file" 0640 root etcd <<EOF; then changed=true; fi
name: $node
data-dir: $data_dir
listen-peer-urls: https://$node_ip:$peer_port
listen-client-urls: $listen_clients
advertise-client-urls: https://$node_ip:$client_port
initial-advertise-peer-urls: https://$node_ip:$peer_port
initial-cluster: $initial_cluster
initial-cluster-state: new
initial-cluster-token: $cluster
logger: zap
log-outputs:
  - stdout
client-transport-security:
  client-cert-auth: true
  trusted-ca-file: $cert_dir/ca.pem
  cert-file: $cert_dir/etcd-server-$node.pem
  key-file: $private_dir/etcd-server-$node.key
peer-transport-security:
  client-cert-auth: true
  trusted-ca-file: $cert_dir/ca.pem
  cert-file: $cert_dir/etcd-peer-$node.pem
  key-file: $private_dir/etcd-peer-$node.key
EOF
    if write_managed "$unit_file" 0644 root root <<EOF; then changed=true; fi
[Unit]
Description=etcd key-value store ($node)
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=etcd
Group=etcd
UMask=0077
WorkingDirectory=$data_dir
ExecStart=$etcd_bin --config-file=$config_file
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
ReadWritePaths=$data_dir
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
    snapshot_script="$bin_root/$version/etcd-snapshot.sh"
    if write_managed "$snapshot_script" 0750 root etcd <<'EOF'; then changed=true; fi
#!/usr/bin/env bash
set -Eeuo pipefail
etcdctl="$1" snapshot_dir="$2" node="$3" config_dir="$4" port="$5"
snapshot="$snapshot_dir/snapshot-$node-$(date -u +%Y%m%dT%H%M%SZ).db"
[[ ! -e "$snapshot" ]] || { echo "snapshot 路径冲突：$snapshot" >&2; exit 1; }
ETCDCTL_API=3 "$etcdctl" --endpoints="https://127.0.0.1:$port" \
  --cacert="$config_dir/pki/ca.pem" --cert="$config_dir/pki/apiserver-etcd-client.pem" \
  --key="$config_dir/pki/private/apiserver-etcd-client.key" snapshot save "$snapshot"
"${etcdctl%etcdctl}etcdutl" snapshot status "$snapshot" --write-out=table >/dev/null
chmod 0600 "$snapshot"
EOF
    if write_managed "$snapshot_service" 0644 root root <<EOF; then changed=true; fi
[Unit]
Description=Create a verified etcd snapshot for $node
After=etcd.service
Requires=etcd.service

[Service]
Type=oneshot
User=etcd
Group=etcd
UMask=0077
ExecStart=$snapshot_script $etcdctl_bin $snapshot_dir $node $config_dir $client_port
LimitNOFILE=65536
LimitNPROC=4096
OOMScoreAdjust=100
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$snapshot_dir
EOF
    if write_managed "$snapshot_timer" 0644 root root <<EOF; then changed=true; fi
[Unit]
Description=Daily verified etcd snapshot for $node

[Timer]
OnCalendar=*-*-* $(printf '%02d' "$snapshot_hour"):00:00
Persistent=true
RandomizedDelaySec=15m
Unit=etcd-snapshot.service

[Install]
WantedBy=timers.target
EOF
    if [[ "$changed" == true ]]; then
        systemctl daemon-reload
        if systemctl is-active --quiet etcd-snapshot.timer; then systemctl restart etcd-snapshot.timer; fi
    fi
    systemctl enable etcd.service etcd-snapshot.timer
elif [[ "$action" == start ]]; then
    systemctl start etcd.service
    systemctl is-active --quiet etcd.service || die "etcd 未进入 active 状态"
    systemctl start etcd-snapshot.timer
else
    systemctl is-active --quiet etcd.service || die "etcd service 未 active"
    systemctl is-active --quiet etcd-snapshot.timer || die "etcd snapshot timer 未 active"
    etcdctl_bin="$bin_root/$version/etcdctl"
    ca="$config_dir/pki/ca.pem"; cert="$config_dir/pki/apiserver-etcd-client.pem"; key="$config_dir/pki/private/apiserver-etcd-client.key"
    for attempt in 1 2 3 4 5; do
        if ETCDCTL_API=3 "$etcdctl_bin" --endpoints="https://127.0.0.1:$client_port" --cacert="$ca" --cert="$cert" --key="$key" endpoint health; then break; fi
        [[ "$attempt" -eq 5 ]] && die "endpoint health 连续失败"
        sleep "$attempt"
    done
    ETCDCTL_API=3 "$etcdctl_bin" --endpoints="https://127.0.0.1:$client_port" --cacert="$ca" --cert="$cert" --key="$key" endpoint status --write-out=table
    member_count="$(ETCDCTL_API=3 "$etcdctl_bin" --endpoints="https://127.0.0.1:$client_port" --cacert="$ca" --cert="$cert" --key="$key" member list | wc -l)"
    [[ "$member_count" -eq "${#master_entries[@]}" ]] || die "etcd member 数 $member_count 与 Master 数 ${#master_entries[@]} 不符"
    systemctl start etcd-snapshot.service
    find "$snapshot_dir" -maxdepth 1 -type f -name "snapshot-$node-*.db" -print -quit | grep -q . || die "没有生成并验证 etcd snapshot"
fi
