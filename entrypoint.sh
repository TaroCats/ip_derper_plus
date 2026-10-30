#!/bin/sh
# ip_derper_plus 容器入口
#
# 关键修复：官方 ghcr.io/tailscale/tailscale 基础镜像里**没有 bash**（只有 ash），
# 而原 Dockerfile 的 CMD 写的是 `bash /app/build_cert.sh ...`，容器一启动就
# `bash: not found`，DERPer 根本起不来。这里统一改用 sh，并把启动逻辑收进脚本，
# 避免 CMD 里塞一长串 && 链（中途失败时无法定位是哪一步挂了）。

set -eu

DERP_CERTS="${DERP_CERTS:-/app/certs}"
DERP_HOST="${DERP_HOST:-127.0.0.1}"
DERP_ADDR="${DERP_ADDR:-:443}"
DERP_HTTP_PORT="${DERP_HTTP_PORT:-80}"
DERP_STUN="${DERP_STUN:-true}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_VERIFY_CLIENTS="${DERP_VERIFY_CLIENTS:-false}"
# derper 的节点私钥配置文件。必须持久化：
# 每次启动若文件缺失，derper 会现场生成一个新的 nodekey，
# 服务端身份随之变化，已配置的 mesh / 防盗链路都会失效。
DERP_CONFIG="${DERP_CONFIG:-/var/lib/derper/derper.key}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"

log() { echo "[entrypoint] $*"; }

# ---------- 1. 生成/复用证书 ----------
sh /app/build_cert.sh "$DERP_HOST" "$DERP_CERTS" /tmp/san.conf

# ---------- 1.5 确保 derper 的节点私钥持久化 ----------
# derper 启动时必须能读到 -c 指定的 config（节点私钥）。
# 不传 -c 时，上游只在 uid==0 的情况下才回退到 /var/lib/derper/derper.key，
# 非 root 运行会直接 fatal: "-c <config path> not specified"。
# 这里显式指定路径并预建目录，不依赖运行用户是不是 root。
mkdir -p "$(dirname "$DERP_CONFIG")"
if [ ! -f "$DERP_CONFIG" ]; then
    log "首次启动，将在 $DERP_CONFIG 生成节点私钥（请确保该路径已挂载持久卷）"
fi

# ---------- 2. 按需启动 tailscaled ----------
# 只有开启防盗（DERP_VERIFY_CLIENTS=true）时才需要本地 tailscaled：
# derper 的 --verify-clients 通过 tailscaled 的 LocalAPI 校验客户端是否属于
# 同一 tailnet。原镜像从未启动过 tailscaled，所以这个开关设了也无效
# （derper 连不上 socket 会直接失败）。
#
# 未开防盗、或没有 authkey 且无历史登录态时，都跳过（零开销）。
need_tailscaled=0
if [ "$DERP_VERIFY_CLIENTS" = "true" ]; then
    if [ -n "$TS_AUTHKEY" ] || [ -f "$TS_STATE_DIR/tailscaled.state" ]; then
        need_tailscaled=1
    else
        log "警告: DERP_VERIFY_CLIENTS=true 但 TS_AUTHKEY 为空且无已保存状态。"
        log "      无法登录 tailnet，防盗校验不可用，已回退为不校验客户端。"
        DERP_VERIFY_CLIENTS=false
    fi
fi

if [ "$need_tailscaled" = "1" ]; then
    log "启动 tailscaled (state=$TS_STATE_DIR socket=$TS_SOCKET)"
    mkdir -p "$TS_STATE_DIR" "$(dirname "$TS_SOCKET")"

    /usr/local/bin/tailscaled \
        --state="$TS_STATE_DIR/tailscaled.state" \
        --socket="$TS_SOCKET" \
        >/tmp/tailscaled.log 2>&1 &
    TS_PID=$!

    # 等 socket 就绪（最多 30s），避免 derper 抢在 tailscaled 之前启动
    n=0
    while [ ! -S "$TS_SOCKET" ]; do
        if ! kill -0 "$TS_PID" 2>/dev/null; then
            log "错误: tailscaled 启动失败，日志:"
            tail -n 30 /tmp/tailscaled.log >&2 || true
            exit 1
        fi
        n=$((n + 1))
        if [ "$n" -gt 60 ]; then
            log "错误: 等待 tailscaled socket 超时，日志:"
            tail -n 30 /tmp/tailscaled.log >&2 || true
            exit 1
        fi
        sleep 0.5
    done

    # 登录 tailnet。已有 state 时 up 是幂等的；首次需要 authkey。
    if [ -n "$TS_AUTHKEY" ]; then
        # shellcheck disable=SC2086
        /usr/local/bin/tailscale --socket="$TS_SOCKET" up \
            --authkey="$TS_AUTHKEY" $TS_EXTRA_ARGS \
            || log "警告: tailscale up 失败，防盗校验可能不可用"
    else
        # shellcheck disable=SC2086
        /usr/local/bin/tailscale --socket="$TS_SOCKET" up $TS_EXTRA_ARGS \
            || log "警告: tailscale up 失败（可能缺少 authkey），防盗校验可能不可用"
    fi
else
    log "跳过 tailscaled（未开启客户端校验）"
fi

# ---------- 3. netcheck（仅诊断，后台跑） ----------
# 原版把 netcheck 串在 && 链里，它一失败整个容器就退出；
# 而且 netcheck 本身要探测 NAT/STUN，耗时十几秒，放在启动关键路径上
# 会白白拖慢 DERP 上线。这里改为后台执行，只写日志。
log "后台运行 netcheck（仅诊断用途）"
( /usr/local/bin/tailscale netcheck >/tmp/netcheck.log 2>&1 || \
  log "netcheck 失败，不影响 derper 启动" ) &

# ---------- 4. 启动 derper ----------
log "启动 derper: host=$DERP_HOST addr=$DERP_ADDR stun=$DERP_STUN verify_clients=$DERP_VERIFY_CLIENTS"

# derper 只在开启防盗时才需要 --socket，其余情况不传，保持与原行为一致
if [ "$need_tailscaled" = "1" ]; then
    SOCKET_ARG="--socket=$TS_SOCKET"
else
    SOCKET_ARG=""
fi

# 用 exec 让 derper 接管 PID 1，docker stop 的 SIGTERM 能直达进程
# shellcheck disable=SC2086
exec /app/derper \
    --hostname="$DERP_HOST" \
    --certmode=manual \
    --certdir="$DERP_CERTS" \
    -c "$DERP_CONFIG" \
    --stun="$DERP_STUN" \
    --a="$DERP_ADDR" \
    --http-port="$DERP_HTTP_PORT" \
    --verify-clients="$DERP_VERIFY_CLIENTS" \
    --stun-port="$DERP_STUN_PORT" \
    $SOCKET_ARG
