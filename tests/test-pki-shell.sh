#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/pki.sh"
# shellcheck source=../bin/common.sh
source "$ROOT/bin/common.sh"
ks_init
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/cluster.env" <<EOF
CLUSTER_NAME=smoke
MASTER_NODES=master-01=192.0.2.10
WORKER_NODES=worker-01=192.0.2.20
SERVICE_CIDR=10.96.0.0/12
CLUSTER_DOMAIN=cluster.local
HARBOR_ENABLED=false
HARBOR_DOMAIN=harbor.192.0.2.30.nip.io
OFFLINE_MODE=false
PKI_DIR=$tmp/pki
CADDY_ROOT=$tmp/www
ARTIFACTS_ROOT=$tmp/artifacts
EOF
CONFIG_ENV="$tmp/cluster.env" CONFIG_VERSIONS="$ROOT/versions.yaml" bash "$ROOT/scripts/02-gen-ca-and-certs.sh" --dry-run >/dev/null
[[ ! -e "$tmp/pki" && ! -e "$tmp/www" && ! -e "$tmp/artifacts" ]]
ks_pki_render "$tmp/pki" smoke 'master-01=192.0.2.10' 'worker-01=192.0.2.20' '10.96.0.0/12' cluster.local false harbor.192.0.2.30.nip.io
[[ "$(wc -l <"$tmp/pki/ca-names.txt")" -eq 3 ]]
[[ "$(wc -l <"$tmp/pki/inventory.tsv")" -eq 14 ]]
grep -Fq '"expiry":"876000h"' "$tmp/pki/ca/kubernetes/ca-config.json"
grep -Fq '"127.0.0.1"' "$tmp/pki/requests/apiserver.json"
grep -Fq '"master-01"' "$tmp/pki/requests/apiserver.json"
grep -Fq '"worker-01"' "$tmp/pki/requests/kubelet-server-worker-01.json"
cfssl_bin="${CFSSL_BIN:-$(command -v cfssl || true)}"
cfssljson_bin="${CFSSLJSON_BIN:-$(command -v cfssljson || true)}"
if [[ -n "$cfssl_bin" && -n "$cfssljson_bin" ]]; then
    while IFS= read -r ca_name; do
        ca_dir="$tmp/pki/ca/$ca_name"
        "$cfssl_bin" gencert -initca -config "$ca_dir/ca-config.json" "$ca_dir/ca-csr.json" \
            | "$cfssljson_bin" -bare "$ca_dir/ca"
        chmod 0644 "$ca_dir/ca.pem"
        chmod 0600 "$ca_dir/ca-key.pem"
    done <"$tmp/pki/ca-names.txt"
    install -d -m 0700 "$tmp/pki/certs"
    while IFS=$'\t' read -r name ca profile _; do
        "$cfssl_bin" gencert -ca "$tmp/pki/ca/$ca/ca.pem" -ca-key "$tmp/pki/ca/$ca/ca-key.pem" \
            -config "$tmp/pki/ca/$ca/ca-config.json" -profile "$profile" "$tmp/pki/requests/$name.json" \
            | "$cfssljson_bin" -bare "$tmp/pki/certs/$name"
        chmod 0644 "$tmp/pki/certs/$name.pem"
        chmod 0600 "$tmp/pki/certs/$name-key.pem"
        rm -f -- "$tmp/pki/certs/$name.csr"
    done <"$tmp/pki/inventory.tsv"
    install -d -m 0700 "$tmp/pki/service-account"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$tmp/pki/service-account/sa.key"
    openssl pkey -in "$tmp/pki/service-account/sa.key" -pubout -out "$tmp/pki/service-account/sa.pub"
    chmod 0600 "$tmp/pki/service-account/sa.key"
    chmod 0644 "$tmp/pki/service-account/sa.pub"
    ks_pki_verify "$tmp/pki" $((876000*60*60))
else
    printf 'SKIP: CFSSL/CFSSLJSON 未提供，未执行 PKI 签发与证书验证集成测试\n'
fi
if grep -RniE 'python(3)?' "$ROOT/scripts" "$ROOT/bin"; then
    printf 'FAIL: deployment entrypoints may not require Python\n' >&2
    exit 1
fi
bash "$ROOT/tests/test-secret-transfer.sh"
printf 'PASS: pure-shell PKI request rendering and deployment Python-free policy\n'

