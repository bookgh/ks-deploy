#!/usr/bin/env python3
"""Render non-secret CFSSL requests and PKI inventory from cluster.env."""

from __future__ import annotations

import argparse
import ipaddress
import json
import sys
from pathlib import Path
from typing import Any

from validate_config import parse_env_text, validate_env

EXPIRY = "876000h"  # 100 x 365 days; CFSSL/Go durations have hour as largest unit.
PROFILE_USAGES = {
    "server": ["signing", "key encipherment", "server auth"],
    "client": ["signing", "key encipherment", "client auth"],
    "peer": ["signing", "key encipherment", "server auth", "client auth"],
}


def node_entries(raw: str) -> list[tuple[str, str]]:
    return [tuple(item.split("=", 1)) for item in raw.split(",")]


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def build_plan(values: dict[str, str], root: Path) -> dict[str, Any]:
    cluster = values["CLUSTER_NAME"]
    masters = node_entries(values["MASTER_NODES"])
    workers = node_entries(values["WORKER_NODES"])
    ca_names = ["kubernetes", "etcd", "front-proxy"]
    if values["HARBOR_ENABLED"] == "true":
        ca_names.append("harbor")

    for ca_name in ca_names:
        ca_dir = root / "ca" / ca_name
        cn = f"ks-deploy {cluster} {ca_name} CA"
        _write_json(ca_dir / "ca-csr.json", {
            "CN": cn,
            "key": {"algo": "rsa", "size": 4096},
            "names": [{"C": "US", "O": cluster, "OU": ca_name}],
            "ca": {"expiry": EXPIRY, "pathlen": 0, "pathlenzero": True},
        })
        _write_json(ca_dir / "ca-config.json", {
            "signing": {
                "default": {"expiry": EXPIRY, "usages": PROFILE_USAGES["peer"]},
                "profiles": {
                    "server": {"expiry": EXPIRY, "usages": PROFILE_USAGES["server"]},
                    "client": {"expiry": EXPIRY, "usages": PROFILE_USAGES["client"]},
                    "peer": {"expiry": EXPIRY, "usages": PROFILE_USAGES["peer"]},
                },
            },
        })

    service_network = ipaddress.ip_network(values["SERVICE_CIDR"], strict=True)
    service_ip = str(service_network.network_address + 1)
    domain = values["CLUSTER_DOMAIN"]
    api_sans = {"127.0.0.1", service_ip, "kubernetes", "kubernetes.default",
                "kubernetes.default.svc", f"kubernetes.default.svc.{domain}"}
    for name, address in masters:
        api_sans.update((name, address))

    inventory: list[dict[str, Any]] = []

    def add_cert(name: str, ca: str, profile: str, cn: str, org: str,
                 hosts: set[str] | list[str] | tuple[str, ...] = (), ou: str = "") -> None:
        sorted_hosts = sorted(set(hosts))
        names = {"C": "US", "O": org}
        if ou:
            names["OU"] = ou
        request = {
            "CN": cn,
            "hosts": sorted_hosts,
            "key": {"algo": "rsa", "size": 2048},
            "names": [names],
        }
        _write_json(root / "requests" / f"{name}.json", request)
        inventory.append({"name": name, "ca": ca, "profile": profile,
                          "cn": cn, "organization": org, "hosts": sorted_hosts})

    add_cert("apiserver", "kubernetes", "server", "kube-apiserver", "system:masters", api_sans)
    add_cert("apiserver-kubelet-client", "kubernetes", "client", "kube-apiserver-kubelet-client", "system:masters")
    add_cert("controller-manager", "kubernetes", "client", "system:kube-controller-manager", "system:kube-controller-manager")
    add_cert("scheduler", "kubernetes", "client", "system:kube-scheduler", "system:kube-scheduler")
    add_cert("admin", "kubernetes", "client", "admin", "system:masters")
    add_cert("kube-proxy", "kubernetes", "client", "system:kube-proxy", "system:node-proxier")
    add_cert("apiserver-etcd-client", "etcd", "client", "kube-apiserver-etcd-client", "system:masters")
    add_cert("front-proxy-client", "front-proxy", "client", "front-proxy-client", "system:admin")

    for name, address in masters:
        hosts = {name, address, "localhost", "127.0.0.1"}
        add_cert(f"etcd-server-{name}", "etcd", "server", name, "etcd", hosts)
        add_cert(f"etcd-peer-{name}", "etcd", "peer", name, "etcd", hosts)

    for name, address in masters + workers:
        add_cert(f"kubelet-client-{name}", "kubernetes", "client",
                 f"system:node:{name}", "system:nodes", ou="system:nodes")
        add_cert(f"kubelet-server-{name}", "kubernetes", "server", name,
                 "system:nodes", {name, address})

    if values["HARBOR_ENABLED"] == "true":
        add_cert("harbor-server", "harbor", "server", values["HARBOR_DOMAIN"],
                 "ks-deploy-harbor", {values["HARBOR_DOMAIN"]})

    plan = {
        "schema_version": 1,
        "cluster": cluster,
        "expiry": EXPIRY,
        "certificate_authorities": ca_names,
        "certificates": inventory,
        "service_ip": service_ip,
    }
    _write_json(root / "inventory.json", plan)
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    values, errors = parse_env_text(args.env.read_text(encoding="utf-8"), str(args.env))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    errors = validate_env(values)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    if args.output.exists() and any(args.output.iterdir()):
        print(f"拒绝覆盖非空 PKI 输出目录：{args.output}", file=sys.stderr)
        return 2
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    build_plan(values, args.output)
    print(f"已渲染 {len(json.loads((args.output / 'inventory.json').read_text())['certificates'])} 个证书请求；此步骤不生成或覆盖私钥")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

