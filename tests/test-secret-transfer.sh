#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/common.sh"
source "$ROOT/bin/pki.sh"
source "$ROOT/bin/secret-transfer.sh"
ks_init
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
install -d -m 0700 "$tmp/source/ca/kubernetes" "$tmp/source/ca/etcd" "$tmp/source/ca/front-proxy" "$tmp/source/certs" "$tmp/source/service-account"
for file in ca/kubernetes/ca.pem ca/etcd/ca.pem ca/front-proxy/ca.pem service-account/sa.key service-account/sa.pub; do
    printf 'test:%s\n' "$file" >"$tmp/source/$file"
done
for name in apiserver apiserver-kubelet-client controller-manager scheduler apiserver-etcd-client front-proxy-client kube-proxy etcd-server-master-01 etcd-peer-master-01 kubelet-client-master-01 kubelet-server-master-01 kubelet-client-worker-01 kubelet-server-worker-01; do
    printf 'certificate:%s\n' "$name" >"$tmp/source/certs/$name.pem"
    printf 'private-key:%s\n' "$name" >"$tmp/source/certs/$name-key.pem"
done
chmod 0600 "$tmp/source/service-account/sa.key" "$tmp/source/certs/"*-key.pem
chmod 0644 "$tmp/source/service-account/sa.pub" "$tmp/source/ca/"*/*.pem "$tmp/source/certs/"*.pem
ks_pki_bundle_for_node "$tmp/source" "$tmp/master" master master-01
ks_pki_bundle_for_node "$tmp/source" "$tmp/worker" worker worker-01
[[ -f "$tmp/master/service-account/sa.key" && -f "$tmp/master/certs/etcd-peer-master-01-key.pem" ]]
[[ ! -e "$tmp/master/certs/admin.pem" && ! -e "$tmp/master/ca/etcd/ca-key.pem" ]]
[[ -f "$tmp/worker/certs/kubelet-client-worker-01-key.pem" && -f "$tmp/worker/ca/kubernetes/ca.pem" ]]
[[ ! -e "$tmp/worker/service-account/sa.key" && ! -e "$tmp/worker/ca/etcd/ca.pem" ]]

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/node.key" 2>/dev/null
openssl pkey -in "$tmp/node.key" -pubout -out "$tmp/node.pub"
install -d -m 0700 "$tmp/encrypted" "$tmp/decrypted" "$tmp/decrypted/unpack"
mapfile -t digests < <(ks_secure_encrypt_bundle "$tmp/master" "$tmp/node.pub" "$tmp/encrypted")
[[ "${#digests[@]}" -eq 3 ]]
openssl pkeyutl -decrypt -inkey "$tmp/node.key" -in "$tmp/encrypted/passphrase.enc" -out "$tmp/encrypted/passphrase" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$tmp/encrypted/passphrase" \
    -in "$tmp/encrypted/payload.enc" -out "$tmp/decrypted/payload.tar.gz"
printf '%s  %s\n' "${digests[0]}" "$tmp/decrypted/payload.tar.gz" | sha256sum --check --status
tar -xzf "$tmp/decrypted/payload.tar.gz" --no-same-owner -C "$tmp/decrypted/unpack"
diff -r "$tmp/master" "$tmp/decrypted/unpack"
printf 'PASS: per-node PKI bundle boundaries and RSA-OAEP/AES-256 encrypted archive round trip\n'

