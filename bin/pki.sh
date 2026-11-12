#!/usr/bin/env bash
# Pure Bash PKI request rendering and OpenSSL verification helpers.
set -euo pipefail

ks_pki_json_string() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ks_pki_ca_config() {
    local dir="$1" name="$2" cluster="$3"
    install -d -m 0700 "$dir"
    cat >"$dir/ca-csr.json" <<EOF
{"CN":"ks-deploy $(ks_pki_json_string "$cluster") $(ks_pki_json_string "$name") CA","key":{"algo":"rsa","size":4096},"names":[{"C":"US","O":"$(ks_pki_json_string "$cluster")","OU":"$name"}],"ca":{"expiry":"876000h","pathlen":0,"pathlenzero":true}}
EOF
    cat >"$dir/ca-config.json" <<'EOF'
{"signing":{"default":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]},"profiles":{"server":{"expiry":"876000h","usages":["signing","key encipherment","server auth"]},"client":{"expiry":"876000h","usages":["signing","key encipherment","client auth"]},"peer":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]}}}}
EOF
    chmod 0600 "$dir/ca-csr.json" "$dir/ca-config.json"
}

ks_pki_request() {
    local root="$1" name="$2" ca="$3" profile="$4" cn="$5" org="$6" ou="$7" hosts="$8" h first=true
    local json_hosts=""; declare -A seen_hosts=()
    IFS=',' read -r -a host_array <<<"$hosts"
    for h in "${host_array[@]}"; do
        [[ -n "$h" ]] || continue
        [[ -z "${seen_hosts[$h]+present}" ]] || continue
        seen_hosts["$h"]=1
        if [[ "$first" == true ]]; then first=false; else json_hosts+=","; fi
        json_hosts+="\"$(ks_pki_json_string "$h")\""
    done
    install -d -m 0700 "$root/requests"
    cat >"$root/requests/$name.json" <<EOF
{"CN":"$(ks_pki_json_string "$cn")","hosts":[$json_hosts],"key":{"algo":"rsa","size":2048},"names":[{"C":"US","O":"$(ks_pki_json_string "$org")"$( [[ -n "$ou" ]] && printf ',"OU":"%s"' "$(ks_pki_json_string "$ou")" )}]}
EOF
    chmod 0600 "$root/requests/$name.json"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$ca" "$profile" "${cn:--}" "${org:--}" "${hosts:--}" >>"$root/inventory.tsv"
}

ks_pki_render() {
    local root="$1" cluster="$2" masters="$3" workers="$4" service_cidr="$5" domain="$6" harbor_enabled="$7" harbor_domain="$8"
    local item name ip ca profile cn org ou hosts service_ip ca_name
    install -d -m 0700 "$root/ca" "$root/requests"
    : >"$root/inventory.tsv"; chmod 0600 "$root/inventory.tsv"
    printf '%s\n' kubernetes etcd front-proxy >"$root/ca-names.txt"
    [[ "$harbor_enabled" != true ]] || printf '%s\n' harbor >>"$root/ca-names.txt"
    while IFS= read -r ca_name; do ks_pki_ca_config "$root/ca/$ca_name" "$ca_name" "$cluster"; done <"$root/ca-names.txt"
    service_ip="$(awk -F'[./]' '{print $1"."$2"."$3"."($4+1)}' <<<"$service_cidr")"
    hosts="127.0.0.1,$service_ip,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.$domain"
    IFS=',' read -r -a entries <<<"$masters"
    for item in "${entries[@]}"; do name="${item%%=*}"; ip="${item#*=}"; hosts+=",$name,$ip"; done
    ks_pki_request "$root" apiserver kubernetes server kube-apiserver system:masters "" "$hosts"
    ks_pki_request "$root" apiserver-kubelet-client kubernetes client kube-apiserver-kubelet-client system:masters "" ""
    ks_pki_request "$root" controller-manager kubernetes client system:kube-controller-manager system:kube-controller-manager "" ""
    ks_pki_request "$root" scheduler kubernetes client system:kube-scheduler system:kube-scheduler "" ""
    ks_pki_request "$root" admin kubernetes client admin system:masters "" ""
    ks_pki_request "$root" kube-proxy kubernetes client system:kube-proxy system:node-proxier "" ""
    ks_pki_request "$root" apiserver-etcd-client etcd client kube-apiserver-etcd-client system:masters "" ""
    ks_pki_request "$root" front-proxy-client front-proxy client front-proxy-client system:admin "" ""
    IFS=',' read -r -a entries <<<"$masters"
    for item in "${entries[@]}"; do
        name="${item%%=*}"; ip="${item#*=}"
        ks_pki_request "$root" "etcd-server-$name" etcd server "$name" etcd "" "$name,$ip,localhost,127.0.0.1"
        ks_pki_request "$root" "etcd-peer-$name" etcd peer "$name" etcd "" "$name,$ip,localhost,127.0.0.1"
    done
    for list in "$masters" "$workers"; do
        IFS=',' read -r -a entries <<<"$list"
        for item in "${entries[@]}"; do
            name="${item%%=*}"; ip="${item#*=}"
            ks_pki_request "$root" "kubelet-client-$name" kubernetes client "system:node:$name" system:nodes system:nodes ""
            ks_pki_request "$root" "kubelet-server-$name" kubernetes server "$name" system:nodes "" "$name,$ip"
        done
    done
    if [[ "$harbor_enabled" == true ]]; then ks_pki_request "$root" harbor-server harbor server "$harbor_domain" ks-deploy-harbor "" "$harbor_domain"; fi
}

ks_pki_verify() {
    local root="$1" expected="$2" cert key ca profile name cn org ou hosts before after seconds diff pub_cert pub_key ca_name host text san_count expected_san_count
    [[ -d "$root" && "$(stat -c '%a' "$root")" == 700 ]] || { ks_die "PKI 根目录权限必须为 0700：$root"; return 1; }
    while IFS= read -r ca_name; do
        cert="$root/ca/$ca_name/ca.pem"; key="$root/ca/$ca_name/ca-key.pem"
        [[ -s "$cert" && -s "$key" && "$(stat -c '%a' "$key")" == 600 ]] || { ks_die "CA 文件缺失或权限错误：$ca_name"; return 1; }
        openssl verify -CAfile "$cert" "$cert" >/dev/null
        text="$(openssl x509 -in "$cert" -noout -text)"
        grep -q 'CA:TRUE' <<<"$text" || { ks_die "CA BasicConstraints 无效：$ca_name"; return 1; }
        grep -q 'Certificate Sign' <<<"$text" || { ks_die "CA KeyUsage 缺少 Certificate Sign：$ca_name"; return 1; }
        pub_cert="$(openssl x509 -in "$cert" -pubkey -noout)"; pub_key="$(openssl pkey -in "$key" -pubout)"
        [[ "$pub_cert" == "$pub_key" ]] || { ks_die "CA 公私钥不匹配：$ca_name"; return 1; }
        ks_pki_check_duration "$cert" "$expected"
    done <"$root/ca-names.txt"
    while IFS=$'\t' read -r name ca profile cn org ou hosts; do
        [[ "$cn" != - ]] || cn=""; [[ "$org" != - ]] || org=""; [[ "$hosts" != - ]] || hosts=""
        cert="$root/certs/$name.pem"; key="$root/certs/$name-key.pem"; ca="$root/ca/$ca/ca.pem"
        [[ -s "$cert" && -s "$key" && "$(stat -c '%a' "$key")" == 600 ]] || { ks_die "叶证书缺失或权限错误：$name"; return 1; }
        openssl verify -CAfile "$ca" "$cert" >/dev/null
        pub_cert="$(openssl x509 -in "$cert" -pubkey -noout)"; pub_key="$(openssl pkey -in "$key" -pubout)"
        [[ "$pub_cert" == "$pub_key" ]] || { ks_die "叶证书公私钥不匹配：$name"; return 1; }
        text="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253)"
        [[ -z "$cn" ]] || grep -Fq "CN=$cn" <<<"$text" || { ks_die "证书 CN 不匹配：$name"; return 1; }
        [[ -z "$org" ]] || grep -Fq "O=$org" <<<"$text" || { ks_die "证书 Organization 不匹配：$name"; return 1; }
        if [[ -n "$hosts" ]]; then
            IFS=',' read -r -a expected_hosts <<<"$hosts"
            expected_san_count="${#expected_hosts[@]}"
            for host in "${expected_hosts[@]}"; do
                if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then openssl x509 -in "$cert" -noout -checkip "$host" >/dev/null
                else openssl x509 -in "$cert" -noout -checkhost "$host" >/dev/null; fi
            done
            san_count="$(openssl x509 -in "$cert" -noout -ext subjectAltName | grep -oE 'DNS:|IP Address:' | wc -l)"
            [[ "$san_count" -eq "$expected_san_count" ]] || { ks_die "SAN 数量与配置不匹配：$name"; return 1; }
        else
            san_count="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:|IP Address:' | wc -l || true)"
            [[ "$san_count" -eq 0 ]] || { ks_die "不应包含 SAN 的证书存在额外 SAN：$name"; return 1; }
        fi
        text="$(openssl x509 -in "$cert" -noout -text)"
        case "$profile" in
            server) grep -q 'TLS Web Server Authentication' <<<"$text" || { ks_die "证书缺少 serverAuth：$name"; return 1; } ;;
            client) grep -q 'TLS Web Client Authentication' <<<"$text" || { ks_die "证书缺少 clientAuth：$name"; return 1; } ;;
            peer) grep -q 'TLS Web Server Authentication' <<<"$text" && grep -q 'TLS Web Client Authentication' <<<"$text" || { ks_die "peer 证书 EKU 不完整：$name"; return 1; } ;;
        esac
        ks_pki_check_duration "$cert" "$expected"
    done <"$root/inventory.tsv"
    [[ -s "$root/service-account/sa.key" && -s "$root/service-account/sa.pub" ]] || { ks_die "ServiceAccount 密钥缺失"; return 1; }
    [[ "$(stat -c '%a' "$root/service-account/sa.key")" == 600 ]] || { ks_die "ServiceAccount 私钥权限必须为 0600"; return 1; }
    [[ "$(openssl pkey -in "$root/service-account/sa.key" -pubout)" == "$(cat "$root/service-account/sa.pub")" ]] || { ks_die "ServiceAccount 密钥不匹配"; return 1; }
    ks_info "PKI 证书链、CN、密钥配对、权限和 $expected 有效期验证通过"
}

ks_pki_check_duration() {
    local cert="$1" expected="$2" before after actual diff
    before="$(openssl x509 -in "$cert" -noout -startdate | cut -d= -f2-)"
    after="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2-)"
    actual=$(( $(date -u -d "$after" +%s) - $(date -u -d "$before" +%s) )); diff=$((actual-expected)); ((diff<0)) && diff=$((-diff))
    ((diff <= 600)) || { ks_die "证书有效期偏离 $expected 秒：$cert ($actual)"; return 1; }
}

