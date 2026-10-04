# Trojan + Hysteria2 一键安装

在自己的 VPS 上安装 **Trojan（TLS/TCP）和 Hysteria2（QUIC/UDP）**。只需输入域名、账号标签、密码和可选端口；脚本自动安装 sing-box、申请证书、创建服务并配置自动续期。

只提供安装、更新程序、卸载三个操作。运行时只需要一个脚本文件。

## 一键安装

先通过 SSH 登录 VPS，使用 **root** 执行以下整行命令，不需要手动上传文件：

```bash
curl -fsSL https://raw.githubusercontent.com/zhysky/dual-proxy-installer/main/install-dual-proxy.sh -o install-dual-proxy.sh && bash install-dual-proxy.sh
```

命令会先下载脚本，只有下载成功才执行。脚本保存在当前目录，可用于后续操作。需要 `curl`；若系统提示找不到该命令，先执行 `apt-get update && apt-get install -y curl ca-certificates`。

使用有 sudo 权限的普通用户时，执行：

```bash
curl -fsSL https://raw.githubusercontent.com/zhysky/dual-proxy-installer/main/install-dual-proxy.sh -o install-dual-proxy.sh && sudo bash install-dual-proxy.sh
```

按提示依次输入：

1. 已解析到本机的完整域名，例如 `proxy.example.com`。
2. 账号名/用户标签。
3. 两个协议共用的密码，再次输入确认；输入时不显示密码。
4. Trojan TCP 端口，直接回车使用 **443**。
5. Hysteria2 UDP 端口，直接回车使用**前一个端口号**。

例如，两个端口都直接回车就是 TCP 443 + UDP 443；也可以分别输入 8443 和 9443。TCP 和 UDP 可以使用相同的数字端口。TCP 80 保留给证书验证，不能作为 Trojan 端口。

## VPS 准备条件

- Ubuntu 22.04+ 或 Debian 12+，使用 systemd；CPU 为 amd64/x86_64 或 arm64/aarch64。
- 域名的 A 记录指向该 VPS。如果存在 AAAA 记录，也必须正确指向本机且公网可达。
- 使用 Cloudflare DNS 时，将该域名设置为“仅 DNS”。
- 云安全组和服务器现有防火墙放行 **TCP 80、所选 Trojan TCP 端口、所选 Hysteria2 UDP 端口**。默认即 TCP 80、TCP 443、UDP 443。
- TCP 80 没有其他程序占用，且在申请和续期证书时可以从公网访问。脚本平时不在 80 上运行网站。
- VPS 能访问 GitHub、发行版软件源和 Let's Encrypt。

脚本会检查端口冲突。已有网站或其他代理占用相关端口时，请先安排好端口；它不会停止其他服务，也不会自动接管 v2ray-agent 等现有安装。脚本不修改防火墙规则。

## 更新程序

使用 root 执行下面一行，即使本机已经没有保存的脚本也可以运行：

```bash
curl -fsSL https://raw.githubusercontent.com/zhysky/dual-proxy-installer/main/install-dual-proxy.sh -o install-dual-proxy.sh && bash install-dual-proxy.sh --update
```

更新 sing-box 到官方最新稳定版，**保留域名、账号密码、端口和证书**，不重新填写配置。

- 校验官方发布文件的 SHA-256、程序版本和现有配置兼容性。
- 当前已经是最新稳定版时直接结束；不会自动降级。
- 新程序启动或端口检查失败时恢复旧程序，并检查原运行状态。
- 更新前手动停止的服务，更新后仍保持停止。
- 不升级系统软件包，也不修改网络调优参数。

## 卸载

使用 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/zhysky/dual-proxy-installer/main/install-dual-proxy.sh -o install-dual-proxy.sh && bash install-dual-proxy.sh --uninstall
```

**该命令直接删除本脚本的服务、配置、账号密码和专用证书数据，不再二次询问。** 需要保留这些数据时，请先备份。

删除范围为 `/etc/dual-proxy/`、`/opt/dual-proxy/`、`/var/lib/dual-proxy/`，以及本脚本创建的三个 systemd 单元：`dual-proxy.service`、`dual-proxy-renew.service`、`dual-proxy-renew.timer`。

只处理有本脚本安装标记的数据；遇到其他所有者或目录符号链接会停止。系统共享软件包、其他代理、其他证书、SSH、防火墙和网络调优保留。共享软件包的系统维护任务也会保留。

普通用户执行更新或卸载时，把对应命令末尾的 `bash` 改成 `sudo bash`。

## 本地脚本参数

如果当前目录已经有脚本，可以直接运行：

| 操作 | 命令 |
| --- | --- |
| 交互安装 | `bash install-dual-proxy.sh` 或 `bash install-dual-proxy.sh --install` |
| 更新程序并保留配置 | `bash install-dual-proxy.sh --update` |
| 卸载并删除本脚本数据 | `bash install-dual-proxy.sh --uninstall` |
| 查看帮助 | `bash install-dual-proxy.sh --help` |

一台服务器由本脚本管理一个双协议实例。已经安装后，请使用 `--update`；需要重新配置时，备份所需数据后卸载再安装。安装中途失败时，专用证书状态可能保留供重试复用。

## 客户端填写

| 字段 | Trojan | Hysteria2 |
| --- | --- | --- |
| 服务器地址 | 输入的域名 | 输入的域名 |
| 端口 | 选择的 TCP 端口 | 选择的 UDP 端口 |
| 密码 | 安装时输入的密码 | 同一个密码 |
| TLS / SNI | 输入的域名 | 输入的域名 |
| ALPN | 使用客户端默认值 | `h3` |

账号名是 sing-box 中的用户标签；客户端实际认证字段是密码，请勿拼成 `账号:密码`。脚本不打印密码或含密码的分享链接。运行所需的密码保存在服务器配置中，文件权限为 0600，专用目录仅 root 可访问。

Hysteria2 启用 `ignore_client_bandwidth=true`，不设置固定的 `up_mbps/down_mbps`。脚本不设置混淆，也不安装额外协议、面板、Nginx、订阅网站或测速功能。

## 服务管理

```bash
# 查看运行状态与近期日志
systemctl status dual-proxy.service --no-pager
journalctl -u dual-proxy.service -n 50 --no-pager

# 查看证书自动续期任务与日志
systemctl list-timers dual-proxy-renew.timer
journalctl -u dual-proxy-renew.service -n 50 --no-pager

# 手动触发一次正常的证书续期检查，不强制重新签发
systemctl start dual-proxy-renew.service
```

配置文件为 `/etc/dual-proxy/config.json`。证书使用 Certbot / Let's Encrypt HTTP-01，无需输入邮箱或 DNS API 凭据。自动续期在服务器本地时间每天 04:00、16:00 检查，各有最多 45 分钟随机延迟；证书更新后校验配置并重载运行中的服务。

## 验证记录与适用范围

首次安装固定使用 **sing-box 1.14.2**，并校验官方 SHA-256。`--update` 从官方 GitHub 发布获取最新稳定版。

当前脚本已通过 Bash 语法检查、ShellCheck，以及 Ubuntu 26.04 amd64 隔离环境中的 **19 项检查**，包括实际 Trojan / Hysteria2 数据传输、错误密码拒绝、同号/不同端口、更新保留配置、失败回滚和卸载范围保护。完整记录见 [validation/2026-10-05.json](validation/2026-10-05.json)，脚本摘要见 [SHA256SUMS](SHA256SUMS)。

验证真实执行了 Bash 交互、OpenSSL 校验、SHA-256、官方 sing-box 核心、协议传输、systemd 单元静态校验、清理和回滚代码。软件包安装、DNS、公网 ACME 签发、GitHub 下载传输、systemd 生命周期控制使用了模拟组件；证书来自私有测试 CA。尚未使用本脚本在全新公网 VPS 上完成实机安装与公开 CA 签发，其他发行版版本及 ARM64 也未实机验证。

## 参考

- 需求参考：[mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)。本仓库是独立实现的精简脚本。
- [sing-box Trojan 入站](https://sing-box.sagernet.org/configuration/inbound/trojan/)
- [sing-box Hysteria2 入站](https://sing-box.sagernet.org/configuration/inbound/hysteria2/)
- [sing-box v1.14.2 官方发布](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2)
- [Certbot standalone / HTTP-01](https://eff-certbot.readthedocs.io/en/stable/using.html#standalone)
