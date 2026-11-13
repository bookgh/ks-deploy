#!/usr/bin/env python3
"""Validate ks-deploy environment, version-lock and Helm chart configuration."""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError

ENV_KEYS = {
    "CLUSTER_NAME", "INSTALL_NODE_IP", "MASTER_NODES", "WORKER_NODES",
    "SSH_USER", "SSH_PORT", "CHRONY_SERVERS", "CADDY_BIND", "CADDY_PORT", "CADDY_ROOT", "CADDY_CONFIG_DIR", "CADDY_BIN_ROOT",
    "POD_CIDR", "SERVICE_CIDR", "CLUSTER_DNS", "CLUSTER_DOMAIN",
    "NODELOCAL_DNS_IP", "CONTAINER_RUNTIME", "PROXY_MODE", "IMAGE_MODE",
    "OFFLINE_MODE", "HARBOR_ENABLED", "HARBOR_NODE_IP", "HARBOR_DOMAIN",
    "HARBOR_SCHEME", "HARBOR_PROJECT", "SELINUX_DISABLE", "FIREWALLD_UNINSTALL", "SWAP_DISABLE",
    "PKI_DIR", "ARTIFACTS_ROOT", "KUBELET_ROOT", "CONTAINERD_ROOT",
    "DOCKER_ROOT", "ETCD_DATA_DIR", "ETCD_BIN_ROOT", "ETCD_CONFIG_DIR",
    "ETCD_SNAPSHOT_DIR", "ETCD_CLIENT_PORT", "ETCD_PEER_PORT", "ETCD_SNAPSHOT_HOUR",
}
BOOLEAN_KEYS = {"OFFLINE_MODE", "HARBOR_ENABLED", "SELINUX_DISABLE", "FIREWALLD_UNINSTALL", "SWAP_DISABLE"}
PATH_KEYS = {"CADDY_ROOT", "CADDY_CONFIG_DIR", "CADDY_BIN_ROOT", "PKI_DIR", "ARTIFACTS_ROOT", "KUBELET_ROOT", "CONTAINERD_ROOT", "DOCKER_ROOT", "ETCD_DATA_DIR", "ETCD_BIN_ROOT", "ETCD_CONFIG_DIR", "ETCD_SNAPSHOT_DIR"}
NUMERIC_IDENTIFIER = r"(?:0|[1-9][0-9]*)"
PRERELEASE_IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
BUILD_IDENTIFIER = r"[0-9A-Za-z-]+"
VERSION_RE = re.compile(
    rf"^v?{NUMERIC_IDENTIFIER}\.{NUMERIC_IDENTIFIER}\.{NUMERIC_IDENTIFIER}"
    rf"(?:-{PRERELEASE_IDENTIFIER}(?:\.{PRERELEASE_IDENTIFIER})*)?"
    rf"(?:\+{BUILD_IDENTIFIER}(?:\.{BUILD_IDENTIFIER})*)?$"
)
NODE_NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
DNS_LABEL_RE = re.compile(r"^[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?$")


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys instead of hiding them."""


def _construct_mapping(loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise ConstructorError("while constructing a mapping", node.start_mark,
                                   "found an unhashable key", key_node.start_mark) from exc
        if duplicate:
            raise ConstructorError("while constructing a mapping", node.start_mark,
                                   f"found duplicate key {key!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def parse_env_text(content: str, source: str) -> tuple[dict[str, str], list[str]]:
    """Parse a deliberately small KEY=value format without executing shell syntax."""
    values: dict[str, str] = {}
    errors: list[str] = []
    for line_number, raw_line in enumerate(content.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            errors.append(f"{source}:{line_number}: 必须使用 KEY=value 格式")
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            errors.append(f"{source}:{line_number}: 非法配置键 {key!r}")
            continue
        if key in values:
            errors.append(f"{source}:{line_number}: 配置键重复：{key}")
            continue
        if key not in ENV_KEYS:
            errors.append(f"{source}:{line_number}: 未知配置项：{key}")
            continue
        if value.startswith(('"', "'")) or value.endswith(('"', "'")):
            if len(value) < 2 or value[0] not in ('"', "'") or value[-1] != value[0]:
                errors.append(f"{source}:{line_number}: {key} 引号不匹配")
                continue
            value = value[1:-1]
        if not re.fullmatch(r"[A-Za-z0-9_.,:/=-]+", value):
            errors.append(f"{source}:{line_number}: {key} 含有不允许的字符；配置值只接受字母、数字和 _.,:/=-")
            continue
        if not value:
            errors.append(f"{source}:{line_number}: {key} 不能为空")
            continue
        values[key] = value

    missing = sorted(ENV_KEYS - values.keys())
    if missing:
        errors.append(f"{source}: 缺少必填配置项：{', '.join(missing)}")
    return values, errors


def _parse_nodes(raw: str, key: str, errors: list[str]) -> list[tuple[str, ipaddress.IPv4Address]]:
    nodes: list[tuple[str, ipaddress.IPv4Address]] = []
    seen_names: set[str] = set()
    for item in raw.split(","):
        if item.count("=") != 1:
            errors.append(f"{key}: 节点格式错误 {item!r}，要求 name=IPv4")
            continue
        name, address = (part.strip() for part in item.split("=", 1))
        if not NODE_NAME_RE.fullmatch(name):
            errors.append(f"{key}: 非法节点名称 {name!r}")
            continue
        if name in seen_names:
            errors.append(f"{key}: 节点名称重复：{name}")
        seen_names.add(name)
        try:
            ip = ipaddress.IPv4Address(address)
        except ipaddress.AddressValueError:
            errors.append(f"{key}: 节点 {name} 的 IPv4 地址非法：{address!r}")
            continue
        nodes.append((name, ip))
    if not nodes:
        errors.append(f"{key}: 至少需要一个有效节点")
    return nodes


def validate_env(values: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for key in BOOLEAN_KEYS:
        if values.get(key) not in {"true", "false"}:
            errors.append(f"{key}: 只允许 true 或 false")

    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", values.get("CLUSTER_NAME", "")):
        errors.append("CLUSTER_NAME: 必须是 DNS 风格的小写名称")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", values.get("SSH_USER", "")):
        errors.append("SSH_USER: 用户名格式非法")

    chrony_servers = values.get("CHRONY_SERVERS", "").split(",")
    if not chrony_servers or any(
        not re.fullmatch(r"(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|(?:[0-9]{1,3}\.){3}[0-9]{1,3})", server)
        for server in chrony_servers
    ):
        errors.append("CHRONY_SERVERS: 必须是以逗号分隔的主机名或 IPv4 地址")

    for key in ("SSH_PORT", "CADDY_PORT", "ETCD_CLIENT_PORT", "ETCD_PEER_PORT"):
        try:
            port = int(values.get(key, ""))
            if not 1 <= port <= 65535:
                raise ValueError
        except ValueError:
            errors.append(f"{key}: 必须是 1-65535 范围内的端口")
    if values.get("ETCD_CLIENT_PORT") == values.get("ETCD_PEER_PORT"):
        errors.append("ETCD_CLIENT_PORT 与 ETCD_PEER_PORT 必须不同")
    try:
        if not 0 <= int(values.get("ETCD_SNAPSHOT_HOUR", "")) <= 23:
            raise ValueError
    except ValueError:
        errors.append("ETCD_SNAPSHOT_HOUR: 必须是 0-23 范围内的小时")

    try:
        bind_ip = ipaddress.ip_address(values.get("CADDY_BIND", ""))
        install_ip = ipaddress.IPv4Address(values.get("INSTALL_NODE_IP", ""))
        if bind_ip.version != 4:
            errors.append("CADDY_BIND: 当前实现仅接受 IPv4 监听地址")
        elif bind_ip != install_ip and bind_ip != ipaddress.IPv4Address("0.0.0.0"):
            errors.append("CADDY_BIND: 必须绑定 INSTALL_NODE_IP；如确需监听全部网卡，显式使用 0.0.0.0")
    except ValueError:
        errors.append("CADDY_BIND 与 INSTALL_NODE_IP: 必须是合法 IPv4 地址")

    master_nodes = _parse_nodes(values.get("MASTER_NODES", ""), "MASTER_NODES", errors)
    worker_nodes = _parse_nodes(values.get("WORKER_NODES", ""), "WORKER_NODES", errors)
    all_nodes = master_nodes + worker_nodes
    seen_ips: dict[ipaddress.IPv4Address, str] = {}
    seen_node_names: set[str] = set()
    for name, address in all_nodes:
        if name in seen_node_names:
            errors.append(f"节点名称重复：{name}")
        seen_node_names.add(name)
        if address in seen_ips:
            errors.append(f"节点 IP 重复：{address} 同时分配给 {seen_ips[address]} 和 {name}")
        else:
            seen_ips[address] = name

    networks: dict[str, ipaddress.IPv4Network] = {}
    for key in ("POD_CIDR", "SERVICE_CIDR"):
        try:
            network = ipaddress.ip_network(values.get(key, ""), strict=True)
            if network.version != 4:
                errors.append(f"{key}: 当前项目仅接受 IPv4 CIDR")
            networks[key] = network
        except ValueError:
            errors.append(f"{key}: 非法 IPv4 CIDR（必须提供规范网络地址，例如 10.244.0.0/16）")
    if len(networks) == 2 and networks["POD_CIDR"].overlaps(networks["SERVICE_CIDR"]):
        errors.append("POD_CIDR 与 SERVICE_CIDR 不允许重叠")
    for name, address in all_nodes:
        if any(address in network for network in networks.values()):
            errors.append(f"节点 {name} 的地址 {address} 不得落入 Pod 或 Service CIDR")

    try:
        cluster_dns = ipaddress.IPv4Address(values.get("CLUSTER_DNS", ""))
        if "SERVICE_CIDR" in networks:
            service_network = networks["SERVICE_CIDR"]
            if cluster_dns not in service_network:
                errors.append("CLUSTER_DNS 必须位于 SERVICE_CIDR 内")
            elif cluster_dns in {service_network.network_address, service_network.broadcast_address}:
                errors.append("CLUSTER_DNS 不得使用 SERVICE_CIDR 的网络地址或广播地址")
    except ipaddress.AddressValueError:
        errors.append("CLUSTER_DNS: 必须是合法 IPv4 地址")
    try:
        nodelocal_ip = ipaddress.IPv4Address(values.get("NODELOCAL_DNS_IP", ""))
        if not nodelocal_ip.is_link_local:
            errors.append("NODELOCAL_DNS_IP: 必须使用 IPv4 link-local 地址（169.254.0.0/16）")
    except ipaddress.AddressValueError:
        errors.append("NODELOCAL_DNS_IP: 必须是合法 IPv4 地址")

    domain = values.get("CLUSTER_DOMAIN", "")
    if len(domain) > 253 or not all(DNS_LABEL_RE.fullmatch(label) for label in domain.split(".")):
        errors.append("CLUSTER_DOMAIN: 必须是合法 DNS 域名")

    if values.get("CONTAINER_RUNTIME") not in {"containerd", "docker"}:
        errors.append("CONTAINER_RUNTIME: 只允许 containerd 或 docker")
    if values.get("PROXY_MODE") not in {"nftables", "ipvs", "iptables"}:
        errors.append("PROXY_MODE: 只允许 nftables、ipvs 或 iptables")
    if values.get("IMAGE_MODE") not in {"online", "offline-harbor", "local-import"}:
        errors.append("IMAGE_MODE: 只允许 online、offline-harbor 或 local-import")

    offline = values.get("OFFLINE_MODE") == "true"
    harbor_enabled = values.get("HARBOR_ENABLED") == "true"
    image_mode = values.get("IMAGE_MODE")
    if image_mode == "online" and offline:
        errors.append("IMAGE_MODE=online 时 OFFLINE_MODE 必须为 false")
    if image_mode == "offline-harbor" and (not offline or not harbor_enabled):
        errors.append("IMAGE_MODE=offline-harbor 要求 OFFLINE_MODE=true 且 HARBOR_ENABLED=true")
    if image_mode == "local-import" and (not offline or values.get("CONTAINER_RUNTIME") != "containerd"):
        errors.append("IMAGE_MODE=local-import 要求 OFFLINE_MODE=true 且 CONTAINER_RUNTIME=containerd")

    if values.get("HARBOR_SCHEME") not in {"http", "https"}:
        errors.append("HARBOR_SCHEME: 只允许 http 或 https")
    if not re.fullmatch(r"[a-z0-9]+(?:[._-][a-z0-9]+)*", values.get("HARBOR_PROJECT", "")):
        errors.append("HARBOR_PROJECT: 项目名称格式非法")
    try:
        harbor_ip = ipaddress.IPv4Address(values.get("HARBOR_NODE_IP", ""))
        expected_domain = f"harbor.{harbor_ip}.nip.io"
        if harbor_enabled and values.get("HARBOR_DOMAIN") != expected_domain:
            errors.append(f"HARBOR_DOMAIN: 启用 Harbor 时必须为 {expected_domain}")
    except ipaddress.AddressValueError:
        if harbor_enabled:
            errors.append("HARBOR_NODE_IP: 启用 Harbor 时必须是合法 IPv4 地址")

    for key in PATH_KEYS:
        path_value = values.get(key, "")
        path = Path(path_value)
        if not path.is_absolute() or ".." in path.parts or any(char.isspace() for char in path_value):
            errors.append(f"{key}: 必须是无空格、无 .. 路径段的绝对路径")
    caddy_root = Path(values.get("CADDY_ROOT", "/"))
    if caddy_root == Path("/"):
        errors.append("CADDY_ROOT: 不得指向文件系统根目录")
    for key in ("CADDY_CONFIG_DIR", "CADDY_BIN_ROOT", "PKI_DIR", "KUBELET_ROOT", "CONTAINERD_ROOT", "DOCKER_ROOT", "ETCD_DATA_DIR", "ETCD_BIN_ROOT", "ETCD_CONFIG_DIR", "ETCD_SNAPSHOT_DIR"):
        protected = Path(values.get(key, "/"))
        if protected == caddy_root or caddy_root in protected.parents:
            errors.append(f"CADDY_ROOT: 不得包含敏感或运行时数据路径 {key}")

    etcd_paths = ("ETCD_DATA_DIR", "ETCD_BIN_ROOT", "ETCD_CONFIG_DIR", "ETCD_SNAPSHOT_DIR", "PKI_DIR")
    for index, left_key in enumerate(etcd_paths):
        left = Path(values.get(left_key, "/"))
        if left == Path("/"):
            errors.append(f"{left_key}: 不得指向文件系统根目录")
        for right_key in etcd_paths[index + 1:]:
            right = Path(values.get(right_key, "/"))
            if left == right or left in right.parents or right in left.parents:
                errors.append(f"etcd 数据、二进制、配置、快照与 PKI 路径不得重叠：{left_key} / {right_key}")

    return errors


def _load_yaml(path: Path, errors: list[str]) -> Any:
    try:
        with path.open("r", encoding="utf-8") as stream:
            return yaml.load(stream, Loader=UniqueKeyLoader)
    except FileNotFoundError:
        errors.append(f"{path}: 文件不存在")
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        errors.append(f"{path}: YAML 读取失败：{exc}")
    return None


def _is_version(value: Any) -> bool:
    return isinstance(value, str) and bool(VERSION_RE.fullmatch(value))


def validate_versions(data: Any, source: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return [f"{source}: 根节点必须是 YAML mapping"]
    expected_top = {"schema_version", "platform", "kubernetes", "components"}
    unknown = set(data) - expected_top
    missing = expected_top - set(data)
    if unknown:
        errors.append(f"{source}: 未知顶层字段：{', '.join(sorted(map(str, unknown)))}")
    if missing:
        errors.append(f"{source}: 缺少顶层字段：{', '.join(sorted(missing))}")
    if type(data.get("schema_version")) is not int or data.get("schema_version") != 1:
        errors.append(f"{source}: schema_version 必须为整数 1")

    platform = data.get("platform")
    if not isinstance(platform, dict):
        errors.append(f"{source}: platform 必须是 mapping")
    elif platform != {"os_family": "rocky", "os_major": 9, "architecture": "amd64"}:
        errors.append(f"{source}: platform 必须精确声明 rocky 9 / amd64")

    kubernetes = data.get("kubernetes")
    if not isinstance(kubernetes, dict):
        errors.append(f"{source}: kubernetes 必须是 mapping")
    else:
        unknown_kubernetes = set(kubernetes) - {"version", "download_base_url", "binaries"}
        if unknown_kubernetes:
            errors.append(f"{source}: kubernetes 存在未知字段：{', '.join(sorted(map(str, unknown_kubernetes)))}")
        version = kubernetes.get("version")
        if not _is_version(version):
            errors.append(f"{source}: kubernetes.version 必须是非空、精确的 SemVer 版本（例如 v1.37.2）")
        base_url = kubernetes.get("download_base_url")
        if not isinstance(base_url, str) or not base_url.startswith("https://"):
            errors.append(f"{source}: kubernetes.download_base_url 必须使用 HTTPS")
        binaries = kubernetes.get("binaries")
        required_binaries = {"kube-apiserver", "kube-controller-manager", "kube-scheduler", "kubelet", "kube-proxy", "kubectl"}
        if not isinstance(binaries, list) or not all(isinstance(item, str) for item in binaries) or set(binaries) != required_binaries:
            errors.append(f"{source}: kubernetes.binaries 必须完整列出 Kubernetes 六个基础二进制")

    components = data.get("components")
    if not isinstance(components, dict):
        errors.append(f"{source}: components 必须是 mapping")
    else:
        for name, config in components.items():
            if not isinstance(name, str) or not isinstance(config, dict):
                errors.append(f"{source}: components 下的每个组件必须是 mapping")
                continue
            checksum_fields = {"checksums_url", "checksums_sha256", "checksums_signature_url", "checksums_signature_sha256", "checksums_certificate_url", "checksums_certificate_sha256", "signature_url", "signature_sha256", "certificate_url", "certificate_sha256"}
            unknown_component = set(config) - {"version", "source_url", "sha256"} - checksum_fields
            if unknown_component:
                errors.append(f"{source}: components.{name} 存在未知字段：{', '.join(sorted(map(str, unknown_component)))}")
            if "version" not in config or not _is_version(config.get("version")):
                errors.append(f"{source}: components.{name}.version 必须是非空精确 SemVer 版本")
            if "source_url" in config and (not isinstance(config["source_url"], str) or not config["source_url"].startswith("https://")):
                errors.append(f"{source}: components.{name}.source_url 必须使用 HTTPS")
            if "source_url" in config:
                digest = config.get("sha256")
                if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                    errors.append(f"{source}: components.{name}.sha256 必须是 64 位小写 SHA256")
            elif "sha256" in config:
                errors.append(f"{source}: components.{name}.sha256 需要同时配置 source_url")
            for field in checksum_fields & set(config):
                if field.endswith("_url") and not str(config[field]).startswith("https://"):
                    errors.append(f"{source}: components.{name}.{field} 必须使用 HTTPS")
                if field.endswith("_sha256") and (not isinstance(config[field], str) or not re.fullmatch(r"[0-9a-f]{64}", config[field])):
                    errors.append(f"{source}: components.{name}.{field} 必须是 64 位小写 SHA256")
            for artifact in ("signature", "certificate", "checksums", "checksums_signature", "checksums_certificate"):
                url_key = f"{artifact}_url"
                digest_key = f"{artifact}_sha256"
                if (url_key in config) != (digest_key in config):
                    errors.append(f"{source}: components.{name}.{artifact} URL 与 SHA256 必须同时配置")
    return errors


def validate_charts(data: Any, source: str) -> list[str]:
    errors: list[str] = []
    expected_charts = {"calico", "coredns", "nodelocaldns"}
    expected_chart_names = {"calico": "tigera-operator", "coredns": "coredns", "nodelocaldns": "nodelocaldns"}
    if not isinstance(data, dict):
        return [f"{source}: 根节点必须是 YAML mapping"]
    if set(data) != {"schema_version", "charts"}:
        errors.append(f"{source}: 顶层字段必须且只能是 schema_version、charts")
    if type(data.get("schema_version")) is not int or data.get("schema_version") != 1:
        errors.append(f"{source}: schema_version 必须为整数 1")
    charts = data.get("charts")
    if not isinstance(charts, dict):
        return errors + [f"{source}: charts 必须是 mapping"]
    missing = expected_charts - set(charts)
    unknown = set(charts) - expected_charts
    if missing:
        errors.append(f"{source}: 缺少 Chart：{', '.join(sorted(missing))}")
    if unknown:
        errors.append(f"{source}: 未知 Chart：{', '.join(sorted(unknown))}")

    for name, config in charts.items():
        if not isinstance(config, dict):
            errors.append(f"{source}: charts.{name} 必须是 mapping")
            continue
        unknown_chart = set(config) - {"repository", "chart", "version_lock_status", "version"}
        if unknown_chart:
            errors.append(f"{source}: charts.{name} 存在未知字段：{', '.join(sorted(map(str, unknown_chart)))}")
        if not isinstance(config.get("chart"), str) or config.get("chart") != expected_chart_names.get(name):
            errors.append(f"{source}: charts.{name}.chart 必须为 {expected_chart_names.get(name)!r}")
        repository = config.get("repository")
        valid_repository = isinstance(repository, str) and (
            repository.startswith("https://") or repository.startswith("oci://") or repository.startswith("local://")
        )
        if not valid_repository:
            errors.append(f"{source}: charts.{name}.repository 必须使用 HTTPS、OCI 或 local:// 来源")
        if isinstance(repository, str) and repository.startswith("local://"):
            local_path = Path(repository[8:])
            if local_path.is_absolute() or ".." in local_path.parts or not local_path.parts:
                errors.append(f"{source}: charts.{name}.repository 必须是仓库内相对路径，且不允许路径穿越")
        lock_status = config.get("version_lock_status")
        if lock_status == "locked":
            if not _is_version(config.get("version")):
                errors.append(f"{source}: charts.{name}.version 锁定时必须填写非空精确 SemVer 版本")
        elif lock_status == "pending":
            if "version" in config:
                errors.append(f"{source}: charts.{name}.version_lock_status=pending 时不得设置 version；完成兼容性审查后再锁定")
        else:
            errors.append(f"{source}: charts.{name}.version_lock_status 只允许 pending 或 locked")
    return errors


def validate_files(env_path: Path, versions_path: Path, charts_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        env_content = env_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"{env_path}: 无法读取：{exc}")
    else:
        env, env_errors = parse_env_text(env_content, str(env_path))
        errors.extend(env_errors)
        if not env_errors:
            errors.extend(validate_env(env))

    versions = _load_yaml(versions_path, errors)
    errors.extend(validate_versions(versions, str(versions_path)))
    charts = _load_yaml(charts_path, errors)
    errors.extend(validate_charts(charts, str(charts_path)))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 ks-deploy 配置文件，不执行配置内容")
    parser.add_argument("--env", type=Path, default=Path("cluster.env.example"), help="KEY=value 环境配置文件")
    parser.add_argument("--versions", type=Path, default=Path("versions.yaml"), help="组件版本锁定文件")
    parser.add_argument("--charts", type=Path, default=Path("charts.yaml"), help="Helm Chart 配置文件")
    args = parser.parse_args()

    errors = validate_files(args.env, args.versions, args.charts)
    if errors:
        for error in errors:
            print(f"错误：{error}", file=sys.stderr)
        print(f"配置校验失败：共发现 {len(errors)} 个问题", file=sys.stderr)
        return 1
    print("配置校验通过：环境配置、版本锁定和 Chart 配置均符合当前 schema")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

