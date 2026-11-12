#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
bash -n "$ROOT/scripts/lib/01-init-system-remote.sh"
printf 'PASS: 远端系统初始化命令模板通过 bash -n\n'

