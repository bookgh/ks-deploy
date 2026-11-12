#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

python3 - "$ROOT/scripts/01-init-system.sh" "$work/remote.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "remote_script='"
end_marker = 'printf "系统初始化完成：%s\\\\n" "$node_name"\''
start = source.index(start_marker) + len(start_marker)
end = source.index(end_marker, start)
template = source[start:end] + 'printf "系统初始化完成：%s\\\\n" "$node_name"'
template = template.replace("'\\\\''", "'")
Path(sys.argv[2]).write_text(template, encoding="utf-8")
PY

bash -n "$work/remote.sh"
printf 'PASS: 远端系统初始化命令模板通过 bash -n\n'

