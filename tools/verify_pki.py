#!/usr/bin/env python3
"""Verify generated PKI names, chains, 100-year validity, keys, and permissions."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import ssl
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

EXPECTED_SECONDS = 876000 * 60 * 60
TIME_TOLERANCE_SECONDS = 600


def run(*args: str) -> bytes:
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def subject_value(cert: dict[str, Any], name: str) -> str:
    for rdn in cert.get("subject", ()):
        for key, value in rdn:
            if key == name:
                return value
    return ""


def verify_key_pair(cert_path: Path, key_path: Path) -> None:
    cert_public = run("openssl", "x509", "-in", str(cert_path), "-pubkey", "-noout")
    key_public = run("openssl", "pkey", "-in", str(key_path), "-pubout")
    expect(cert_public.strip() == key_public.strip(), f"证书和私钥不匹配：{cert_path.name}")
    mode = stat.S_IMODE(key_path.stat().st_mode)
    expect(mode == 0o600, f"私钥权限必须为 0600：{key_path} 当前 {mode:04o}")


def verify_ca(root: Path, name: str) -> Path:
    cert_path = root / "ca" / name / "ca.pem"
    key_path = root / "ca" / name / "ca-key.pem"
    expect(cert_path.is_file() and key_path.is_file(), f"缺少 {name} CA 证书或私钥")
    verify_key_pair(cert_path, key_path)
    cert = ssl._ssl._test_decode_cert(str(cert_path))
    expect("CA:TRUE" in run("openssl", "x509", "-in", str(cert_path), "-noout", "-text").decode(),
           f"CA BasicConstraints 无效：{name}")
    expect("Certificate Sign" in run("openssl", "x509", "-in", str(cert_path), "-noout", "-text").decode(),
           f"CA KeyUsage 缺少 Certificate Sign：{name}")
    validity = ssl.cert_time_to_seconds(cert["notAfter"]) - ssl.cert_time_to_seconds(cert["notBefore"])
    expect(abs(validity - EXPECTED_SECONDS) <= TIME_TOLERANCE_SECONDS,
           f"CA 有效期不是 876000h：{name} 实际 {validity} 秒")
    run("openssl", "verify", "-CAfile", str(cert_path), str(cert_path))
    return cert_path


def decode_sans(cert: dict[str, Any]) -> set[str]:
    sans: set[str] = set()
    for kind, value in cert.get("subjectAltName", ()):
        if kind == "IP Address":
            sans.add(str(ipaddress.ip_address(value)))
        elif kind == "DNS":
            sans.add(value)
    return sans


def verify_leaf(root: Path, item: dict[str, Any], ca_path: Path) -> None:
    name = item["name"]
    cert_path = root / "certs" / f"{name}.pem"
    key_path = root / "certs" / f"{name}-key.pem"
    expect(cert_path.is_file() and key_path.is_file(), f"缺少证书或私钥：{name}")
    verify_key_pair(cert_path, key_path)
    run("openssl", "verify", "-CAfile", str(ca_path), str(cert_path))
    cert = ssl._ssl._test_decode_cert(str(cert_path))
    expect(subject_value(cert, "commonName") == item["cn"], f"CN 不匹配：{name}")
    expect(subject_value(cert, "organizationName") == item["organization"], f"Organization 不匹配：{name}")
    expect(decode_sans(cert) == set(item["hosts"]), f"SAN 不匹配：{name}")
    validity = ssl.cert_time_to_seconds(cert["notAfter"]) - ssl.cert_time_to_seconds(cert["notBefore"])
    expect(abs(validity - EXPECTED_SECONDS) <= TIME_TOLERANCE_SECONDS,
           f"叶证书有效期不是 876000h：{name} 实际 {validity} 秒")
    text = run("openssl", "x509", "-in", str(cert_path), "-noout", "-text").decode()
    expect("Digital Signature" in text, f"KeyUsage 缺少 Digital Signature：{name}")
    usage_section = re.search(r"X509v3 Extended Key Usage:\s*\n\s*([^\n]+)", text)
    expect(usage_section is not None, f"ExtendedKeyUsage 缺失：{name}")
    usages = usage_section.group(1)
    profile = item["profile"]
    if profile in {"server", "peer"}:
        expect("TLS Web Server Authentication" in usages, f"缺少 serverAuth：{name}")
    if profile in {"client", "peer"}:
        expect("TLS Web Client Authentication" in usages, f"缺少 clientAuth：{name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pki-dir", type=Path, required=True)
    args = parser.parse_args()
    root = args.pki_dir
    try:
        inventory = json.loads((root / "inventory.json").read_text(encoding="utf-8"))
        expect(inventory.get("schema_version") == 1, "PKI inventory schema_version 无效")
        expect(stat.S_IMODE(root.stat().st_mode) == 0o700, f"PKI 根目录权限必须为 0700：{root}")
        cas = {name: verify_ca(root, name) for name in inventory["certificate_authorities"]}
        for item in inventory["certificates"]:
            verify_leaf(root, item, cas[item["ca"]])
        sa_key = root / "service-account" / "sa.key"
        sa_pub = root / "service-account" / "sa.pub"
        expect(sa_key.is_file() and sa_pub.is_file(), "缺少 ServiceAccount signing key pair")
        expect(stat.S_IMODE(sa_key.stat().st_mode) == 0o600, "ServiceAccount 私钥权限必须为 0600")
        expect(run("openssl", "pkey", "-in", str(sa_key), "-pubout").strip() == sa_pub.read_bytes().strip(),
               "ServiceAccount 公私钥不匹配")
    except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"PKI 校验失败：{exc}", file=sys.stderr)
        return 1
    print(f"PKI 校验通过：{len(inventory['certificate_authorities'])} 个 CA、{len(inventory['certificates'])} 张叶证书；权限、链、SAN、用途与 876000h 有效期均匹配")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

