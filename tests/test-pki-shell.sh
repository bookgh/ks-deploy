#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/pki.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
ks_pki_render "$tmp/pki" smoke 'master-01=192.0.2.10' 'worker-01=192.0.2.20' '10.96.0.0/12' cluster.local false harbor.192.0.2.30.nip.io
[[ "$(wc -l <"$tmp/pki/ca-names.txt")" -eq 3 ]]
[[ "$(wc -l <"$tmp/pki/inventory.tsv")" -eq 14 ]]
grep -Fq '"expiry":"876000h"' "$tmp/pki/ca/kubernetes/ca-config.json"
grep -Fq '"127.0.0.1"' "$tmp/pki/requests/apiserver.json"
grep -Fq '"master-01"' "$tmp/pki/requests/apiserver.json"
grep -Fq '"worker-01"' "$tmp/pki/requests/kubelet-server-worker-01.json"
if grep -RniE 'python(3)?' "$ROOT/scripts" "$ROOT/bin"; then
    printf 'FAIL: deployment entrypoints may not require Python\n' >&2
    exit 1
fi
printf 'PASS: pure-shell PKI request rendering and deployment Python-free policy\n'

