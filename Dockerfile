# syntax=docker/dockerfile:1

# =============================================================================
# ip_derper_plus
#
# 相比原版的关键修复（详见 README 的「修复记录」）：
#   1. 基础镜像 ghcr.io/tailscale/tailscale 是 alpine，**没有 bash**，而原 CMD 用
#      `bash` 调脚本 —— 容器启动即 bash: not found，DERPer 根本起不来。改用 sh。
#   2. LABEL 写在 builder 阶段，最终镜像继承不到（GHCR 无法关联源码仓库）。
#      已移到最终阶段。
#   3. golang:latest 与 tailscale:latest 两个浮动 tag 让构建不可复现，
#      上游一改就可能构建失败或行为漂移。改为可覆盖的固定 ARG。
#   4. 原 `COPY . /app` 把 101MB 的 .git 也塞进构建上下文，且每次任意文件改动
#      都会击穿依赖缓存。改为分层 COPY（先 go.mod/go.sum 拉依赖，再拷源码）。
#   5. 源码补丁 sed 静默失败风险：上游一改代码块，sed 不匹配但编译照过，
#      到运行期才炸。现在补丁后强制校验，失败则构建中断。
#   6. 多架构：builder 固定在 BUILDPLATFORM 上交叉编译，arm64 构建无需 QEMU。
# =============================================================================

ARG GO_VERSION=1.25
ARG TAILSCALE_IMAGE_VERSION=v1.92.4

# -----------------------------------------------------------------------------
# Stage 1: 构建 derper
# 固定在本机（构建机）架构上跑，用 GOARCH=$TARGETARCH 交叉编译，
# 这样 linux/arm64 构建不需要 QEMU 模拟，速度快一个数量级。
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64
# 注入版本信息，便于运行时 tailscale version / debug 排查
ARG DERP_VERSION=dev

RUN apk add --no-cache ca-certificates git

WORKDIR /src

# 先只拷 go.mod / go.sum，让依赖下载独立成层。
# 只要依赖不变，改源码不会重新下载依赖（原版每次都重新拉一遍）。
COPY tailscale/go.mod tailscale/go.sum ./tailscale/
RUN cd tailscale && go mod download

# 再拷源码（含 submodule 工作树，.dockerignore 已排除 .git）
COPY tailscale/ ./tailscale/

# 打补丁：移除 derper manual 模式下对客户端 SNI 与 hostname 的一致性检查。
# 补丁逻辑收在 patch_derper.sh 里，带完整校验：上游改版导致 sed 不匹配时
# 会直接构建失败，而不是静默产出一个「补丁没打上」的镜像。
COPY patch_derper.sh /tmp/patch_derper.sh
RUN sh /tmp/patch_derper.sh /src/tailscale && rm -f /tmp/patch_derper.sh

# 编译。CGO_ENABLED=0 => 静态二进制，不依赖目标机的 libc。
RUN cd /src/tailscale && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X tailscale.com/version.longStamp=${DERP_VERSION}" \
      -o /out/derper ./cmd/derper

# -----------------------------------------------------------------------------
# Stage 2: 运行镜像
# 直接复用官方 tailscale 镜像的 alpine 基础环境（自带 tailscale/tailscaled/
# containerboot，以及 tun 设备与 iptables 等运行时依赖可正常工作）。
# -----------------------------------------------------------------------------
FROM ghcr.io/tailscale/tailscale:${TAILSCALE_IMAGE_VERSION}

# 注意：LABEL 必须在最终阶段声明，否则不会出现在成品镜像里。
LABEL org.opencontainers.image.source="https://github.com/skyhhjmk/ip_derper_plus"
LABEL org.opencontainers.image.title="ip_derper_plus"
LABEL org.opencontainers.image.description="Tailscale DERP relay server with self-signed cert support and no domain requirement"

WORKDIR /app

# ========= CONFIG =========
ENV DERP_ADDR=:443
ENV DERP_HTTP_PORT=80
ENV DERP_HOST=127.0.0.1
ENV DERP_CERTS=/app/certs
ENV DERP_STUN=true
ENV DERP_STUN_PORT=3478
# derper 的节点私钥文件，必须持久化（缺失时 derper 会生成新 nodekey）
ENV DERP_CONFIG=/var/lib/derper/derper.key
# 不修改，兼容旧版
ENV DERP_VERIFY_CLIENTS=false
# 适配自带防盗（需要 net_admin + tun，且 DERP_VERIFY_CLIENTS=true 时才真正启用）
ENV TS_AUTHKEY=""
ENV TS_STATE_DIR=/var/lib/tailscale
ENV TS_EXTRA_ARGS="--advertise-tags=tag:container"
# ==========================

# 证书生成只需要 openssl；curl 用于健康检查
RUN apk add --no-cache openssl curl && \
    mkdir -p /app/certs /var/lib/derper

# 复制构建产物与脚本
COPY --from=builder /out/derper /app/derper
COPY build_cert.sh entrypoint.sh /app/
RUN chmod +x /app/derper /app/build_cert.sh /app/entrypoint.sh

# 暴露端口（仅元数据，实际监听由 DERP_* 环境变量决定）
EXPOSE 443 80 3478/udp

# 健康检查：用 derper 的 /generate_204 而不是 /derp/probe。
# 原因：80 端口上的 /derp/probe 会被 Port80Handler 308 重定向到 https://，
# 而 https 是自签证书，curl 校验必然失败。/generate_204 在 80 端口有独立
# 处理器、直接返回 204，不受重定向影响。
# 注意：DERP_HTTP_PORT=-1 会关闭 80 端口，此时需自行覆盖 healthcheck。
HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS -o /dev/null "http://127.0.0.1:${DERP_HTTP_PORT}/generate_204" || exit 1

# CMD 必须显式清空：基础镜像自带 CMD ["/usr/local/bin/containerboot"]，
# 子镜像设 ENTRYPOINT 后，父镜像的 CMD 会变成它的默认参数被传进来，
# 导致 entrypoint.sh 收到一个多余的 containerboot 参数。
CMD []

# 用 ENTRYPOINT 而不是 CMD：derper 作为 PID 1 接管信号，
# docker stop 能立即生效，不必等 10s SIGKILL 才强杀。
ENTRYPOINT ["/app/entrypoint.sh"]
