#!/bin/sh
# 生成 derper manual 模式所需的自签名证书
#
# 用法: build_cert.sh <host> <cert_dir> [conf_file]
#
# 相比原版的修复：
#   1. 域名场景原先写死 "IP.1 = <host>"，openssl 解析 IP 类型的 SAN 遇到域名会直接
#      报 "Error Loading extension section v3_req" 并生成失败 —— 现按 host 类型自动
#      选用 DNS.x / IP.x。
#   2. 原版 mkdir -p "/$CERT_DIR" 多了一个根斜杠，会在文件系统根目录下建出
#      /app/certs 之类的怪路径，真实证书目录反而不存在 —— 已改为 "$CERT_DIR"。
#   3. 原版每次容器启动都无条件重新签发证书。manual + self-signed IP 模式下，
#      客户端 DERPMap 里写的是证书哈希（CertName: sha256-raw:...），重启换证书
#      会让已配置的节点全部失效 —— 现在证书已存在就复用，只有缺失或显式
#      FORCE_CERT_REGEN=1 时才重签。
#   4. 私钥权限收紧到 600，避免挂载到共享卷时被其他容器读到。

set -eu

CERT_HOST="${1:?host is required}"
CERT_DIR="${2:?cert dir is required}"
CONF_FILE="${3:-/tmp/san.conf}"

FORCE_CERT_REGEN="${FORCE_CERT_REGEN:-0}"

# derper 的 NewManualCertManager 会用 [^a-zA-Z0-9-.] 过滤 hostname 得到文件名，
# 这里必须保持完全一致的规则，否则 derper 找不到我们生成的证书。
KEYNAME=$(printf '%s' "$CERT_HOST" | tr -cd 'a-zA-Z0-9-.')

CRT="$CERT_DIR/$KEYNAME.crt"
KEY="$CERT_DIR/$KEYNAME.key"

mkdir -p "$CERT_DIR"

if [ -f "$CRT" ] && [ -f "$KEY" ] && [ "$FORCE_CERT_REGEN" != "1" ]; then
    echo "[cert] 复用已有证书: $CRT"
    exit 0
fi

# 判断 host 是 IPv4/IPv6 还是域名。IPv6 含冒号，域名不含。
case "$CERT_HOST" in
    *:*)
        SAN_LINE="IP.1 = $CERT_HOST"
        ;;
    *[!0-9.]*)
        # 含非数字/点字符 -> 域名
        SAN_LINE="DNS.1 = $CERT_HOST"
        ;;
    *)
        SAN_LINE="IP.1 = $CERT_HOST"
        ;;
esac

cat > "$CONF_FILE" <<EOF
[req]
default_bits  = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
countryName = XX
stateOrProvinceName = N/A
localityName = N/A
organizationName = Self-signed certificate
commonName = $CERT_HOST

[req_ext]
subjectAltName = @alt_names

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$SAN_LINE
EOF

echo "[cert] 为 $CERT_HOST 签发自签名证书 ($SAN_LINE)"
openssl req -x509 -nodes -days 730 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CRT" -config "$CONF_FILE" 2>/dev/null

chmod 600 "$KEY"
chmod 644 "$CRT"

echo "[cert] 完成: $CRT"
