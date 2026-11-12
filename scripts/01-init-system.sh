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
    chown -R ks-deploy-http:ks-deploy-http "$staging"
    chmod 0755 "$staging"
}

remote_script='set -Eeuo pipefail
[[ "$(id -u)" == 0 ]] || { echo "远端必须以 root 登录" >&2; exit 40; }
[[ "$(uname -m)" == x86_64 ]] || { echo "目标架构不是 amd64" >&2; exit 41; }
source /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID%%.*}" == 9 ]] || { echo "目标系统不是 Rocky Linux 9" >&2; exit 42; }
for command in curl sha256sum install sysctl modprobe systemctl hostnamectl python3 grep cmp cp date swapon; do
    command -v "$command" >/dev/null 2>&1 || { echo "缺少命令：$command" >&2; exit 43; }
done
[[ -x /usr/sbin/chronyd || -x /usr/bin/chronyd ]] || { echo "未安装 chrony，请先准备 Rocky 9 RPM 依赖" >&2; exit 44; }
[[ -r /etc/chrony.conf && -r /etc/hosts ]] || { echo "缺少 /etc/chrony.conf 或 /etc/hosts" >&2; exit 46; }
work="$(mktemp -d)"
trap '\''rm -rf -- "$work"'\'' EXIT
base="$1"
shift
for _ in 1 2 3 4 5; do
    name="$1"; digest="$2"; shift 2
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 120 --output "$work/$name" "$base/$name"
    printf "%s  %s\\n" "$digest" "$work/$name" | sha256sum --check --status || { echo "SHA256 校验失败：$name" >&2; exit 45; }
done
node_name="$1"; selinux_disable="$2"; firewall_uninstall="$3"; swap_disable="$4"
[[ "$selinux_disable" != true || -r /etc/selinux/config ]] || { echo "SELinux 配置文件不可读" >&2; exit 47; }
if [[ "$firewall_uninstall" == true ]]; then
    command -v rpm >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1 || { echo "移除 firewalld 需要 rpm 与 dnf" >&2; exit 48; }
fi
if [[ "$swap_disable" == true ]]; then command -v swapoff >/dev/null 2>&1 || { echo "禁用 swap 需要 swapoff" >&2; exit 49; }; fi
install_managed() {
    local source="$1" destination="$2" mode="$3"
    if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then return; fi
    if [[ -e "$destination" ]]; then cp -a "$destination" "$destination.ks-deploy.bak.$(date -u +%Y%m%dT%H%M%SZ)"; fi
    install -D -m "$mode" "$source" "$destination"
    if [[ "$destination" == /etc/chrony.d/ks-deploy.sources ]]; then chrony_changed=true; fi
}
install_managed "$work/10-ks-deploy.conf" /etc/sysctl.d/10-ks-deploy.conf 0644
install_managed "$work/10-ks-deploy.modules" /etc/modules-load.d/10-ks-deploy.conf 0644
install_managed "$work/90-ks-deploy.limits" /etc/security/limits.d/90-ks-deploy.conf 0644
install -d -m 0755 /etc/chrony.d
chrony_changed=false
install_managed "$work/ks-deploy.sources" /etc/chrony.d/ks-deploy.sources 0644
if ! grep -Eq "^[[:space:]]*confdir[[:space:]]+/etc/chrony.d([[:space:]]|$)" /etc/chrony.conf; then
    cp -a /etc/chrony.conf "/etc/chrony.conf.ks-deploy.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    printf "\\nconfdir /etc/chrony.d\\n" >>/etc/chrony.conf
    chrony_changed=true
fi
python3 - "$work/hosts.block" <<'\''PY'\''
from pathlib import Path
import shutil
import sys

path = Path("/etc/hosts")
begin, end = "# BEGIN ks-deploy managed nodes", "# END ks-deploy managed nodes"
text = path.read_text(encoding="utf-8")
if (begin in text) != (end in text):
    raise SystemExit("/etc/hosts 中 ks-deploy 管理标记不匹配，已停止")
start = text.find(begin)
if start >= 0:
    finish = text.find(end, start) + len(end)
    if text.find(begin, start + 1) >= 0 or text.find(end, finish) >= 0:
        raise SystemExit("/etc/hosts 中存在重复 ks-deploy 管理块，已停止")
    text = text[:start].rstrip("\n") + "\n" + text[finish:].lstrip("\n")
block = begin + "\n" + Path(sys.argv[1]).read_text(encoding="utf-8").rstrip() + "\n" + end
updated = (text.rstrip("\n") + "\n" + block + "\n") if text else block + "\n"
if updated != path.read_text(encoding="utf-8"):
    shutil.copy2(path, path.with_name(path.name + ".ks-deploy.bak." + __import__("time").strftime("%Y%m%dT%H%M%SZ", __import__("time").gmtime())))
    temp = path.with_name(path.name + ".ks-deploy.tmp")
    temp.write_text(updated, encoding="utf-8")
    temp.chmod(path.stat().st_mode & 0o777)
    temp.replace(path)
PY
hostnamectl set-hostname "$node_name"
for module in overlay br_netfilter nf_conntrack; do modprobe "$module"; done
sysctl --system >/dev/null
systemctl enable chronyd
if systemctl is-active --quiet chronyd; then
    [[ "$chrony_changed" != true ]] || systemctl restart chronyd
else
    systemctl start chronyd
fi
chronyc sources -n >/dev/null
if [[ "$selinux_disable" == true ]]; then
    mode="$(getenforce 2>/dev/null || true)"
    [[ "$mode" != Enforcing ]] || setenforce 0
    python3 - <<'\''PY'\''
from pathlib import Path
import shutil
import time

path = Path("/etc/selinux/config")
text = path.read_text(encoding="utf-8")
lines = ["SELINUX=disabled" if line.startswith("SELINUX=") else line for line in text.splitlines()]
if not any(line.startswith("SELINUX=") for line in lines):
    lines.append("SELINUX=disabled")
updated = "\n".join(lines) + "\n"
if updated != text:
    shutil.copy2(path, path.with_name(path.name + ".ks-deploy.bak." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    path.write_text(updated, encoding="utf-8")
PY
fi
if [[ "$firewall_uninstall" == true ]] && rpm -q firewalld >/dev/null 2>&1; then
    systemctl disable --now firewalld
    dnf remove -y firewalld
fi
[[ "$(hostnamectl --static)" == "$node_name" ]]
sysctl -n net.ipv4.ip_forward | grep -qx 1
systemctl is-active --quiet chronyd
if [[ "$swap_disable" == true ]]; then
    swapoff --all
    python3 - <<'\''PY'\''
from pathlib import Path
import shutil
import time

path = Path("/etc/fstab")
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
updated_lines = []
changed = False
for line in lines:
    fields = line.split()
    if fields and not line.lstrip().startswith("#") and len(fields) >= 3 and fields[2] == "swap":
        updated_lines.append("# ks-deploy disabled swap entry: " + line)
        changed = True
    else:
        updated_lines.append(line)
if changed:
    shutil.copy2(path, path.with_name(path.name + ".ks-deploy.bak." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    temp = path.with_name(path.name + ".ks-deploy.tmp")
    temp.write_text("".join(updated_lines), encoding="utf-8")
    temp.chmod(path.stat().st_mode & 0o777)
    temp.replace(path)
PY
    [[ -z "$(swapon --show --noheadings)" ]] || { echo "swap 仍处于启用状态" >&2; exit 50; }
fi
printf "系统初始化完成：%s\\n" "$node_name"'

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

