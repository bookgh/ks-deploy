#!/usr/bin/env bash
set -euo pipefail

cfssl_bin="${CFSSL_BIN:-$(command -v cfssl || true)}"
cfssljson_bin="${CFSSLJSON_BIN:-$(command -v cfssljson || true)}"
if [[ -z "$cfssl_bin" || -z "$cfssljson_bin" ]]; then
    printf 'SKIP: CFSSL 未安装；设置 CFSSL_BIN 和 CFSSLJSON_BIN 才能实测 876000h\n'
    exit 0
fi
for command in openssl date; do
    command -v "$command" >/dev/null 2>&1 || { printf 'FAIL: 缺少命令 %s\n' "$command" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cat >"$work/ca-config.json" <<'EOF'
{
  "signing": {
    "default": {"expiry": "876000h", "usages": ["signing", "key encipherment", "server auth", "client auth"]},
    "profiles": {
      "server": {"expiry": "876000h", "usages": ["signing", "key encipherment", "server auth"]}
    }
  }
}
EOF
cat >"$work/ca-csr.json" <<'EOF'
{
  "CN": "ks-deploy duration test CA",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"C": "US", "O": "ks-deploy", "OU": "duration-test"}],
  "ca": {"expiry": "876000h", "pathlen": 0, "pathlenzero": true}
}
EOF
cat >"$work/server-csr.json" <<'EOF'
{
  "CN": "duration-test.example.invalid",
  "hosts": ["duration-test.example.invalid", "127.0.0.1"],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"C": "US", "O": "ks-deploy", "OU": "duration-test"}]
}
EOF

"$cfssl_bin" gencert -initca -config "$work/ca-config.json" "$work/ca-csr.json" \
    | "$cfssljson_bin" -bare "$work/ca"
"$cfssl_bin" gencert -ca "$work/ca.pem" -ca-key "$work/ca-key.pem" \
    -config "$work/ca-config.json" -profile server "$work/server-csr.json" \
    | "$cfssljson_bin" -bare "$work/server"

expected=$((876000 * 60 * 60))
for certificate in "$work/ca.pem" "$work/server.pem"; do
    not_before="$(openssl x509 -in "$certificate" -noout -startdate | cut -d= -f2-)"
    not_after="$(openssl x509 -in "$certificate" -noout -enddate | cut -d= -f2-)"
    actual=$(( $(date -u -d "$not_after" +%s) - $(date -u -d "$not_before" +%s) ))
    delta=$((actual - expected))
    ((delta < 0)) && delta=$((-delta))
    ((delta <= 600)) || { printf 'FAIL: %s validity is %s seconds, expected %s\n' "$certificate" "$actual" "$expected" >&2; exit 1; }
done
printf 'PASS: CFSSL CA and server profile accept expiry=876000h and emit 100-year certificates\n'

