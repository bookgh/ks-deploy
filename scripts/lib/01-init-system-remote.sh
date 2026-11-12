#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" == 0 ]] || { echo "远端必须以 root 登录" >&2; exit 40; }
[[ "$(uname -m)" == x86_64 ]] || { echo "目标架构不是 amd64" >&2; exit 41; }
source /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID%%.*}" == 9 ]] || { echo "目标系统不是 Rocky Linux 9" >&2; exit 42; }
for command in curl sha256sum install sysctl modprobe systemctl hostnamectl grep cmp cp date swapon awk sed; do
    command -v "$command" >/dev/null 2>&1 || { echo "缺少命令：$command" >&2; exit 43; }
done
[[ -x /usr/sbin/chronyd || -x /usr/bin/chronyd ]] || { echo "未安装 chrony，请先准备 Rocky 9 RPM 依赖" >&2; exit 44; }
[[ -r /etc/chrony.conf && -r /etc/hosts ]] || { echo "缺少 /etc/chrony.conf 或 /etc/hosts" >&2; exit 46; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
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
hosts=/etc/hosts
begin='# BEGIN ks-deploy managed nodes'; end='# END ks-deploy managed nodes'
begin_count="$(grep -Fc "$begin" "$hosts" || true)"
end_count="$(grep -Fc "$end" "$hosts" || true)"
[[ "$begin_count" == "$end_count" && "$begin_count" -le 1 ]] || { echo "/etc/hosts 管理标记缺失或重复，停止" >&2; exit 51; }
tmp_hosts="$work/hosts.updated"
if [[ "$begin_count" == 1 ]]; then
    awk -v b="$begin" -v e="$end" 'BEGIN{skip=0} $0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$hosts" >"$tmp_hosts"
    [[ "$(grep -Fc "$end" "$hosts" || true)" == 1 ]] || { echo "/etc/hosts 管理块结束标记缺失" >&2; exit 51; }
else
    cat "$hosts" >"$tmp_hosts"
fi
printf '\n%s\n' "$begin" >>"$tmp_hosts"
cat "$work/hosts.block" >>"$tmp_hosts"
printf '%s\n' "$end" >>"$tmp_hosts"
if ! cmp -s "$tmp_hosts" "$hosts"; then
    cp -a "$hosts" "$hosts.ks-deploy.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    install -m "$(stat -c %a "$hosts")" "$tmp_hosts" "$hosts"
fi
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
    selinux_file=/etc/selinux/config
    if ! grep -qx 'SELINUX=disabled' "$selinux_file"; then
        cp -a "$selinux_file" "$selinux_file.ks-deploy.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        if grep -q '^SELINUX=' "$selinux_file"; then sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$selinux_file"; else printf '\nSELINUX=disabled\n' >>"$selinux_file"; fi
    fi
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
    fstab=/etc/fstab
    if awk '!/^[[:space:]]*#/ && NF>=3 && $3=="swap" {found=1} END{exit !found}' "$fstab"; then
        cp -a "$fstab" "$fstab.ks-deploy.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        awk '{if ($0 !~ /^[[:space:]]*#/ && NF>=3 && $3=="swap") print "# ks-deploy disabled swap entry: " $0; else print}' "$fstab" >"$work/fstab.updated"
        install -m "$(stat -c %a "$fstab")" "$work/fstab.updated" "$fstab"
    fi
    [[ -z "$(swapon --show --noheadings)" ]] || { echo "swap 仍处于启用状态" >&2; exit 50; }
fi
printf "系统初始化完成：%s\\n" "$node_name"
