#!/usr/bin/env python3
"""Fetch locked official CFSSL test binaries and verify their SHA256 digests."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import tempfile
import urllib.request
from pathlib import Path
from typing import Any

import yaml


def fetch(component: dict[str, Any], name: str, output: Path) -> Path:
    url = component.get("source_url")
    expected = component.get("sha256")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ValueError(f"{name}: source_url must use HTTPS")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"{name}: locked SHA256 is missing")
    destination = output / name
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if destination.exists():
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
            raise ValueError(f"{destination}: existing file SHA256 mismatch")
        return destination
    fd, temporary_name = tempfile.mkstemp(prefix=f".{name}.", dir=output)
    temporary = Path(temporary_name)
    digest = hashlib.sha256()
    total = 0
    try:
        with os.fdopen(fd, "wb") as target, urllib.request.urlopen(url, timeout=60) as response:
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > 64 * 1024 * 1024:
                    raise ValueError(f"{name}: artifact exceeds 64 MiB safety limit")
                digest.update(chunk)
                target.write(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f"{name}: downloaded artifact SHA256 mismatch")
        temporary.chmod(0o700)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--versions", type=Path, default=Path("versions.yaml"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    components = yaml.safe_load(args.versions.read_text(encoding="utf-8"))["components"]
    cfssl = fetch(components["cfssl"], "cfssl", args.output)
    cfssljson = fetch(components["cfssljson"], "cfssljson", args.output)
    print(f"CFSSL_BIN={cfssl}")
    print(f"CFSSLJSON_BIN={cfssljson}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

