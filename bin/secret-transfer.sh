#!/usr/bin/env bash
# Encrypt private PKI bundles to a node key, distribute ciphertext over Caddy HTTP,
# and install only after SSH-authenticated digests and local file modes are checked.
set -euo pipefail

ks_secure_encrypt_bundle() {
    local source_dir="$1" public_key="$2" work_dir="$3" plain_sha cipher_sha wrapped_sha
    [[ -d "$source_dir" && -d "$work_dir" ]] || { ks_die "加密源目录或临时目录不存在"; return 1; }
    [[ -z "$(find "$source_dir" -type l -print -quit)" ]] || { ks_die "私有证书包禁止包含符号链接"; return 1; }
    tar -C "$source_dir" -czf "$work_dir/payload.tar.gz" -- .
    plain_sha="$(sha256sum "$work_dir/payload.tar.gz" | awk '{print $1}')"
    openssl rand -hex 32 >"$work_dir/passphrase"
    chmod 0600 "$work_dir/passphrase"
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass "file:$work_dir/passphrase" \
        -in "$work_dir/payload.tar.gz" -out "$work_dir/payload.enc"
    openssl pkeyutl -encrypt -pubin -inkey "$public_key" -in "$work_dir/passphrase" \
        -out "$work_dir/passphrase.enc" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256
    cipher_sha="$(sha256sum "$work_dir/payload.enc" | awk '{print $1}')"
    wrapped_sha="$(sha256sum "$work_dir/passphrase.enc" | awk '{print $1}')"
    printf '%s\n%s\n%s\n' "$plain_sha" "$cipher_sha" "$wrapped_sha"
}

ks_secure_send() (
    local host="$1" node="$2" source_dir="$3" target_root="$4"
    local caddy_root install_ip caddy_port base_url run_id stage_dir work_dir
    local key_path remote_key_script remote_receive_script public_key cipher_sha wrapped_sha plain_sha
    caddy_root="$(ks_config_get CADDY_ROOT)"
    install_ip="$(ks_config_get INSTALL_NODE_IP)"
    caddy_port="$(ks_config_get CADDY_PORT)"
    base_url="http://$install_ip:$caddy_port"
    [[ -d "$source_dir" ]] || { ks_die "私有制品源目录不存在：$source_dir"; return 1; }
    [[ "$node" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || { ks_die "节点名称不合法，拒绝密钥传输：$node"; return 1; }
    [[ "$target_root" == /* && "$target_root" != *..* ]] || { ks_die "远端秘密目标目录必须是安全绝对路径：$target_root"; return 1; }
    if [[ "$KS_DRY_RUN" == true ]]; then
        ks_info "Dry-run：将为节点 $node 生成 RSA 加密证书包并通过 $base_url HTTP 下载；不会写文件或连接节点"
        return 0
    fi
    work_dir="$(mktemp -d)"
    run_id="${work_dir##*/}"
    stage_dir="$caddy_root/secure-transfer/$run_id"
    trap 'rm -rf -- "$work_dir" "$stage_dir"' EXIT
    chmod 0700 "$work_dir"

    key_path="$target_root/.transport/$node.key"
    read -r -d '' remote_key_script <<'REMOTE' || true
set -Eeuo pipefail
key_path="$1"
key_dir="$(dirname -- "$key_path")"
target_root="$(dirname -- "$key_dir")"
for directory in "$target_root" "$key_dir"; do
    [[ ! -L "$directory" ]] || { echo "拒绝跟随秘密目录符号链接：$directory" >&2; exit 70; }
    if [[ -e "$directory" ]]; then
        [[ -d "$directory" && "$(stat -c '%a' "$directory")" == 700 ]] || { echo "秘密目录权限/类型错误：$directory" >&2; exit 70; }
    else
        install -d -m 0700 "$directory"
    fi
done
[[ ! -L "$key_path" ]] || { echo "拒绝跟随传输私钥符号链接" >&2; exit 71; }
if [[ ! -e "$key_path" ]]; then
    temporary="$(mktemp "$key_dir/.key.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$temporary"
    chmod 0600 "$temporary"
    if [[ -e "$key_path" ]]; then rm -f -- "$temporary"; else mv -- "$temporary" "$key_path"; fi
fi
[[ -f "$key_path" && "$(stat -c '%a' "$key_path")" == 600 ]] || { echo "传输私钥权限/类型错误" >&2; exit 72; }
openssl pkey -in "$key_path" -check -noout >/dev/null
openssl pkey -in "$key_path" -pubout
REMOTE
    public_key="$(ks_ssh_exec "$host" 2 15 /bin/bash -c "$remote_key_script" ks-secret-key "$key_path")"
    printf '%s\n' "$public_key" >"$work_dir/node.pub"
    openssl pkey -pubin -in "$work_dir/node.pub" -noout >/dev/null || { ks_die "节点 $node 返回的加密公钥无效"; return 1; }

    mapfile -t crypto_meta < <(ks_secure_encrypt_bundle "$source_dir" "$work_dir/node.pub" "$work_dir")
    ((${#crypto_meta[@]} == 3)) || { ks_die "无法生成加密证书包校验和"; return 1; }
    plain_sha="${crypto_meta[0]}"; cipher_sha="${crypto_meta[1]}"; wrapped_sha="${crypto_meta[2]}"

    install -d -o ks-deploy-http -g ks-deploy-http -m 0750 "$stage_dir"
    install -o ks-deploy-http -g ks-deploy-http -m 0640 "$work_dir/payload.enc" "$stage_dir/payload.enc"
    install -o ks-deploy-http -g ks-deploy-http -m 0640 "$work_dir/passphrase.enc" "$stage_dir/passphrase.enc"
    base_url="$base_url/secure-transfer/$run_id"

    read -r -d '' remote_receive_script <<'REMOTE' || true
set -Eeuo pipefail
key_path="$1" payload_url="$2" payload_sha="$3" wrapped_url="$4" wrapped_sha="$5"
plain_sha="$6" target="$7"
for digest in "$payload_sha" "$wrapped_sha" "$plain_sha"; do
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || { echo "SHA256 参数非法" >&2; exit 73; }
done
[[ "$target" == /* && "$target" != *..* ]] || { echo "目标路径非法" >&2; exit 74; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
curl --proto '=http,https' --fail --location --silent --show-error --connect-timeout 10 --max-time 180 --output "$work/payload.enc" "$payload_url"
curl --proto '=http,https' --fail --location --silent --show-error --connect-timeout 10 --max-time 180 --output "$work/passphrase.enc" "$wrapped_url"
printf '%s  %s\n' "$payload_sha" "$work/payload.enc" | sha256sum --check --status || { echo "加密归档 SHA256 不匹配" >&2; exit 75; }
printf '%s  %s\n' "$wrapped_sha" "$work/passphrase.enc" | sha256sum --check --status || { echo "加密密钥 SHA256 不匹配" >&2; exit 76; }
openssl pkeyutl -decrypt -inkey "$key_path" -in "$work/passphrase.enc" -out "$work/passphrase" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$work/passphrase" \
    -in "$work/payload.enc" -out "$work/payload.tar.gz"
printf '%s  %s\n' "$plain_sha" "$work/payload.tar.gz" | sha256sum --check --status || { echo "解密归档 SHA256 不匹配" >&2; exit 77; }
tar -tzf "$work/payload.tar.gz" | awk '/^\// || /(^|\/)\.\.(\/|$)/ {bad=1} END {if (bad || NR==0) exit 1}' || { echo "归档路径非法或为空" >&2; exit 78; }
tar -tvzf "$work/payload.tar.gz" | awk 'substr($1,1,1)!="-" && substr($1,1,1)!="d" {bad=1} END {exit bad}' || { echo "拒绝安装归档中的链接或特殊文件" >&2; exit 79; }
mkdir -m 0700 "$work/unpack"
tar -xzf "$work/payload.tar.gz" --no-same-owner -C "$work/unpack"
if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" && "$(stat -c '%a' "$target")" == 700 ]] || { echo "节点 PKI 目录权限/类型错误" >&2; exit 80; }
else
    install -d -m 0700 "$target"
fi
while IFS= read -r -d '' source; do
    relative="${source#"$work/unpack/"}"
    [[ "$relative" != /* && "$relative" != *../* && "$relative" != .. ]] || { echo "归档文件路径非法" >&2; exit 80; }
    destination="$target/$relative"
    case "$relative" in *-key.pem|*.key) mode=0600 ;; *) mode=0644 ;; esac
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] || { echo "目标文件类型冲突：$destination" >&2; exit 81; }
        cmp -s "$source" "$destination" || { echo "目标文件内容冲突，拒绝覆盖：$destination" >&2; exit 82; }
        [[ "$(stat -c '%a' "$destination")" == "$mode" ]] || { echo "目标文件权限错误：$destination" >&2; exit 83; }
        continue
    fi
    parent="$(dirname -- "$destination")"
    [[ ! -L "$parent" ]] || { echo "拒绝跟随 PKI 子目录符号链接：$parent" >&2; exit 84; }
    if [[ -e "$parent" ]]; then
        [[ -d "$parent" && "$(stat -c '%a' "$parent")" == 700 ]] || { echo "PKI 子目录权限/类型错误：$parent" >&2; exit 84; }
    else
        install -d -m 0700 "$parent"
    fi
    temporary="$destination.ks-deploy.$$"
    install -m "$mode" "$source" "$temporary"
    mv -- "$temporary" "$destination"
done < <(find "$work/unpack" -type f -print0)
REMOTE
    ks_ssh_exec "$host" 2 15 /bin/bash -c "$remote_receive_script" ks-secret-receive \
        "$key_path" "$base_url/payload.enc" "$cipher_sha" "$base_url/passphrase.enc" "$wrapped_sha" "$plain_sha" "$target_root/$node"
    ks_info "节点 $node 私有证书包已加密传输并逐文件验证（目标：$target_root/$node）"
)

ks_pki_bundle_for_node() {
    local source="$1" destination="$2" role="$3" node="$4" path
    [[ "$node" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || { ks_die "节点名称不合法，不能构造证书包：$node"; return 1; }
    install -d -m 0700 "$destination"
    ks_bundle_add() {
        local relative="$1"
        install -D -m 0600 "$source/$relative" "$destination/$relative"
        if [[ "$relative" == *.pem && "$relative" != *-key.pem ]]; then
            chmod 0644 "$destination/$relative"
        fi
    }
    ks_bundle_add ca/kubernetes/ca.pem
    if [[ "$role" == master ]]; then
        ks_bundle_add ca/etcd/ca.pem
        ks_bundle_add ca/front-proxy/ca.pem
        for path in apiserver apiserver-kubelet-client controller-manager scheduler apiserver-etcd-client front-proxy-client kube-proxy "etcd-server-$node" "etcd-peer-$node" "kubelet-client-$node" "kubelet-server-$node"; do
            ks_bundle_add "certs/$path.pem"
            ks_bundle_add "certs/$path-key.pem"
        done
        install -d -m 0700 "$destination/service-account"
        install -m 0600 "$source/service-account/sa.key" "$destination/service-account/sa.key"
        install -m 0644 "$source/service-account/sa.pub" "$destination/service-account/sa.pub"
    else
        for path in "kubelet-client-$node" "kubelet-server-$node" kube-proxy; do
            ks_bundle_add "certs/$path.pem"
            ks_bundle_add "certs/$path-key.pem"
        done
    fi
}

