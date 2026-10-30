#!/bin/sh
# 为 derper 打上「跳过 SNI/hostname 一致性校验」补丁
#
# 上游行为：manual 证书模式下，getCertificate 会校验 TLS ClientHello 的
# ServerName 是否等于 --hostname，不等就报 "cert mismatch with hostname"。
# 当 derper 用「域名 + 自签证书」时，客户端 SNI 与配置值稍有差异就握手失败，
# 本 patch 直接删除这段校验。
#
# 注意：hostname 为纯 IP 时上游自己会设 noHostname=true 跳过检查，
# 所以这个补丁的实际价值主要在域名场景。
#
# 用法: patch_derper.sh <tailscale 源码根目录>
#
# 兼容性：alpine 的 BusyBox sed 与 GNU sed 的 -i 参数不同，这里统一先从
# stdin/stdout 过滤，再回写，避免踩 -i 的坑。

set -eu

SRC_DIR="${1:?需要传入 tailscale 源码目录}"
TARGET="$SRC_DIR/cmd/derper/cert.go"
PATTERN='hi\.ServerName != m\.hostname'

if [ ! -f "$TARGET" ]; then
    echo "错误: 找不到 $TARGET" >&2
    exit 1
fi

# 先确认目标代码存在。若不存在，说明上游改版了 —— 必须中断，
# 绝不能静默跳过（否则构建通过但 SNI 校验还在，域名场景会运行期失败）。
if ! grep -q "$PATTERN" "$TARGET"; then
    echo "错误: 未找到待删除的 SNI 校验代码，上游 cert.go 可能已改版。" >&2
    echo "       请检查 $TARGET 中 getCertificate 的实现后更新本补丁。" >&2
    exit 1
fi

BEFORE=$(wc -l < "$TARGET")
TMP="$TARGET.patched"
# 删除匹配行及其后 2 行：if 判断 + return 错误 + 闭括号
sed "/$PATTERN/,+2d" "$TARGET" > "$TMP"
AFTER=$(wc -l < "$TMP")

if [ "$AFTER" -ge "$BEFORE" ]; then
    echo "错误: 补丁未能删除任何内容（before=$BEFORE after=$AFTER）" >&2
    rm -f "$TMP"
    exit 1
fi

if grep -q "$PATTERN" "$TMP"; then
    echo "错误: 补丁后仍残留 SNI 校验代码" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$TARGET"
echo "OK: SNI 校验补丁已生效（$BEFORE -> $AFTER 行）"
