本项目从 [ip_derper](https://github.com/yangchuansheng/ip_derper) 分支而来并独立维护。

# IP DERPer Plus

## 项目介绍

DERPer 是 Tailscale 的中转服务器，用于处理 Tailscale 客户端的连接请求，在无法打洞时转为私有协议进行连接。

目前 Tailscale 官方提供了可用但不太稳定的 DERP 服务器，并允许用户使用自己的域名部署 DERP 服务器，但不是每个人都有空余的域名愿意用来部署
DERP 服务器，于是诞生了 ip_derper 项目。

> 若需要使用防盗功能，则必须有 net_admin 权限和 tun 设备。可惜的是，这在使用雨云云应用部署时是无法实现的。

## 使用方法

雨云免费一键部署（云应用不支持防盗，请看 README.md 的 NOTE 部分）

[![通过雨云一键部署](https://rainyun-apps.cn-nb1.rains3.com/materials/deploy-on-rainyun-cn.svg)](https://app.rainyun.com/apps/rca/store/7021/github_?s=github_app7021)

> Ads: 雨云优惠码 `github` 可享新用户 5 折优惠和永久折扣以及消费积分返利

您需要在 Tailscale 控制台生成一个脚本，并且将 `--auth-key` 后的内容复制下来，传入环境变量 `TS_AUTHKEY` 中即可。

![img.png](img/img.png)

## 环境变量

| 环境变量名               | 默认值                              | 说明                                          |
|---------------------|----------------------------------|---------------------------------------------|
| DERP_ADDR           | :443                             | HTTPS 监听地址                                  |
| DERP_HTTP_PORT      | 80                               | HTTP 端口，设为 -1 关闭                          |
| DERP_HOST           | 127.0.0.1                        | 证书 CN/SAN 与 hostname。**填 IP 或域名都可以**        |
| DERP_CERTS          | /app/certs/                      | 证书目录                                        |
| DERP_CONFIG         | /var/lib/derper/derper.key       | derper 节点私钥，**必须持久化**，否则重启后节点身份变化 |
| DERP_STUN           | true                             | 是否开启 STUN                                   |
| DERP_STUN_PORT      | 3478                             | STUN UDP 端口                                  |
| DERP_VERIFY_CLIENTS | false                            | 防盗开关。`true` 时必须同时提供 `TS_AUTHKEY`             |
| TS_AUTHKEY          | ""                               | Tailscale authkey，仅防盗场景需要                   |
| TS_STATE_DIR        | /var/lib/tailscale               | tailscaled 状态目录，建议挂卷持久化                      |
| TS_EXTRA_ARGS       | "--advertise-tags=tag:container" | `tailscale up` 附加参数                         |
| TS_SOCKET           | /var/run/tailscale/tailscaled.sock | tailscaled 与 derper 通信的 socket 路径（可选）    |
| FORCE_CERT_REGEN    | 0                                | 设为 1 时强制重新签发自签证书                            |

### 快速运行

```sh
docker run -d --name derper \
  --restart unless-stopped \
  -p 443:443 -p 80:80 -p 3478:3478/udp \
  -e DERP_HOST=<你的公网IP或域名> \
  -v derper-certs:/app/certs \
  -v derper-nodekey:/var/lib/derper \
  ghcr.io/tarocats/ip_derper_plus:latest
```

需要防盗（会启动 tailscaled，必须加权限）：

```sh
docker run -d --name derper \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -e DERP_HOST=<公网IP> \
  -e DERP_VERIFY_CLIENTS=true \
  -e TS_AUTHKEY=tskey-auth-xxxx \
  -v derper-certs:/app/certs \
  -v derper-nodekey:/var/lib/derper \
  -v derper-state:/var/lib/tailscale \
  ghcr.io/tarocats/ip_derper_plus:latest
```

## 修复记录

本次对打包流程与运行逻辑做了一轮系统性修复，涉及以下问题：

### 致命问题

1. **容器根本起不来（bash 不存在）**
   基础镜像 `ghcr.io/tailscale/tailscale` 是 alpine，只有 `ash` 和 `sh`，**没有 bash**，
   而原 `CMD` 写的是 `bash /app/build_cert.sh ...`。容器启动即报 `bash: not found`，DERPer 从未真正跑起来。
   已改为 `sh` + `ENTRYPOINT` 脚本。

2. **域名场景证书生成直接失败**
   `build_cert.sh` 把 host 无条件写进 `IP.1 = <host>`。当 `DERP_HOST` 是域名时，
   openssl 解析 IP 类型 SAN 遇到域名会报 `Error Loading extension section v3_req` 并拒绝生成证书。
   现已按 host 类型自动选择 `DNS.1` / `IP.1`。

3. **证书目录路径写错**
   原 `mkdir -p "/$CERT_DIR"` 多了一个根斜杠，`CERT_DIR=/app/certs` 时会在根目录下建出 `/app/certs`，
   而 openssl 输出到相对路径 `app/certs`，两者不一致，目录可能不存在导致签发失败。

4. **防盗功能形同虚设**
   镜像里从未启动过 `tailscaled`，而 `--verify-clients` 依赖 tailscaled 的 LocalAPI 校验客户端。
   即使把 `DERP_VERIFY_CLIENTS` 设为 `true`，derper 也连不上 socket。
   现在开启防盗时会按需后台拉 tailscaled、等待 socket 就绪后再 `tailscale up`。

### 稳定性与可维护性

5. **缺少 `-c` 配置路径 / 节点私钥不持久化**
   上游 derper 启动时必须能读到 nodekey 配置文件。不传 `-c` 时它只在 uid==0 下回退到
   `/var/lib/derper/derper.key`，非 root 运行会直接 `fatal: -c <config path> not specified`；
   而且该文件若不在持久卷上，容器重启就会生成新 nodekey，节点身份变化、mesh 与防盗链路全部失效。
   现在显式传 `-c` 并预建目录，README 也要求挂载 `/var/lib/derper`。

6. **`netcheck` 失败会拖死整个容器**
   原 `CMD` 用 `&&` 串联，`tailscale netcheck` 只是一条诊断输出，一旦失败容器立刻退出；
   而且它要探测 NAT/STUN，耗时十几秒，白占启动关键路径。
   现已改为后台执行、失败仅记日志。

7. **证书每次启动都重签**
   IP + self-signed 模式下，客户端 DERPMap 里记录的是证书哈希（`CertName: sha256-raw:...`），
   重启换新证书会让已配置的节点全部失效。现在已存在就复用，只在缺失或 `FORCE_CERT_REGEN=1` 时重签。

8. **`LABEL` 写在了 builder 阶段**
   最终镜像继承不到，导致 GHCR 无法关联源码仓库，也看不到包说明。已移到最终 stage。

9. **derper 不是 PID 1**
   原用 `CMD` + `bash -c`，`docker stop` 发的 SIGTERM 打到 bash 而非 derper，只能等 10s 后 SIGKILL。
   现在 `exec derper` 接管 PID 1，`docker stop` 立即生效。

10. **健康检查端点选错**
    原先有 `HEALTHCHECK` 但被注释掉了。且不能直接用 `/derp/probe`：实测在 80 端口它会被
    `Port80Handler` 返回 **302** 跳到 https，而 https 是自签证书、curl 校验必然失败。
    已改用 80 端口上独立处理、直接返回 204 的 `/generate_204`。

### 打包流程

11. **构建不可复现**
    `golang:latest` + `tailscale:latest` 两个浮动 tag，上游一改就可能构建失败或行为漂移。
    改为 `ARG GO_VERSION` / `ARG TAILSCALE_IMAGE_VERSION`，可显式覆盖。

12. **缓存完全失效**
    原 `COPY . /app` 把 101MB 的 `.git` 一起塞进上下文，且任何文件改动都会让 `go build` 全量重来。
    现在先拷 `go.mod`/`go.sum` 拉依赖、再拷源码，依赖层可长期复用；并新增 `.dockerignore`。

13. **补丁静默失败**
    原来的 `sed` 补丁不校验结果：上游改版后 sed 匹配不到，编译照样通过，问题要拖到运行期才暴露。
    现在抽成 `patch_derper.sh`，带行数校验与目标串残留校验，失败直接中断构建。

13. **CI 从不运行镜像**
    原工作流只 build + push，所以上面第 1 条那种「镜像起不来」的问题一直没被发现。
    新增 `smoke-test` job：真实启动容器、校验进程存活、校验 `/generate_204` 返回 204、校验证书 SAN 正确。

14. **多架构支持**
    builder 固定在 `$BUILDPLATFORM` 上交叉编译，arm64 构建无需 QEMU 模拟；
    CI 同时产出 `linux/amd64` 与 `linux/arm64`。

15. **submodule 同步工作流 token 混用**
    checkout 用 `secrets.CI_TOKEN`、push 时又把 remote 改写成 `GITHUB_TOKEN`，两套权限互相打架。
    统一为 `GITHUB_TOKEN`，并加上「无变更则跳过」与并发推送失败重试。

## 本地构建

```sh
# 需要先检出 submodule
git submodule update --init --recursive

# 单架构
docker build -t ip_derper_plus:local .

# 多架构（需 buildx）
docker buildx build --platform linux/amd64,linux/arm64 -t ip_derper_plus:local .
```

## NOTE

尝试了多种方式都无法在雨云云应用环境启动 tailscale+derper 服务，目前带防盗功能的仅支持 vm 中部署或自有 k8s 中部署。

防盗功能需要容器具备 `NET_ADMIN` 权限与 `/dev/net/tun` 设备，且建议直接使用 `--network host`，
否则 STUN 与 DERP 的端口映射在 NAT 后面容易出问题。
