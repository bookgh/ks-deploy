#!/usr/bin/env bash
set -Eeuo pipefail
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
python3 - "$work/hosts.block" <<'PY'
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
    python3 - <<'PY'
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
    python3 - <<'PY'
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
printf "系统初始化完成：%s\\n" "$node_name"

