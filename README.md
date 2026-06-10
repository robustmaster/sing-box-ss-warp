# sing-box-ss-warp

一键在 VPS 上安装 `sing-box`，同时提供两个 Shadowsocks 节点：

- `direct`：走 VPS 自己的公网 IP 出口。
- `warp`：走 Cloudflare WARP 出口。

两个节点都支持 TCP 和 UDP。WARP 不依赖 `warp-cli proxy`，而是使用 `sing-box` 自己的 WireGuard endpoint。

支持系统：

```text
Debian / Ubuntu：apt
RedHat / Fedora / Rocky / Alma：dnf
```

CPU 架构只支持：

```text
amd64
arm64
```

## 一键安装

先 SSH 登录 VPS，并切到 root：

```bash
sudo -i
```

然后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | bash
```

安装完成后查看节点信息：

```bash
cat /root/sing-box-ss-warp.txt
```

里面会有 direct / warp 两个节点的端口、密码和 `ss://` 链接。

## 默认配置

脚本默认会：

- 安装 `sing-box`
- 下载 `wgcf`，生成 Cloudflare WARP WireGuard profile
- 创建两个 Shadowsocks 入口
- 自动生成 Shadowsocks 密码
- 放行 UFW 的 TCP/UDP 端口，如果 UFW 已启用
- 在 Debian/Ubuntu 上配置自动更新
- 停用不再需要的 `warp-svc`
- 配置 `sing-box` 异常退出后自动重启
- 验证 direct / warp 的 TCP 和 UDP 是否可用

## 依赖

脚本会下载 [ViRb3/wgcf](https://github.com/ViRb3/wgcf) 的 Linux 二进制，用来注册 Cloudflare WARP 账号并生成 WireGuard profile。

脚本会按 VPS 的 CPU 架构自动选择 `wgcf` 版本：

```text
x86_64 / amd64  -> linux_amd64
aarch64 / arm64 -> linux_arm64
```

如果自动识别不准，可以手动指定：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  WGCF_ARCH=arm64 bash
```

`wgcf` 只在安装/生成 profile 时使用，不是常驻服务。安装完成后，WARP 出口由 `sing-box` 的 WireGuard endpoint 提供。

`sing-box` 本身通过 SagerNet 的 APT/DNF 源安装，实际可用架构取决于该源提供的包。

默认端口：

```text
direct: 55221
warp:   36243
```

默认加密：

```text
2022-blake3-aes-256-gcm
```

## 自定义端口

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  DIRECT_PORT=24701 WARP_PORT=55513 bash
```

## 使用兼容性更好的加密方式

如果你的客户端不支持 `2022-blake3-aes-256-gcm`，可以用：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  SS_METHOD=chacha20-ietf-poly1305 bash
```

## 指定密码

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  DIRECT_PASSWORD='your-direct-password' \
  WARP_PASSWORD='your-warp-password' \
  bash
```

## 指定服务器 IP

一般不需要。脚本会自动检测公网 IP。

如果自动检测失败，可以手动指定：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  SERVER_IP=1.2.3.4 bash
```

## 重新生成 WARP 身份

第一次运行时，脚本会自动注册一个新的 WARP profile。

如果 `/root/sing-box-wgcf/wgcf-account.toml` 已经存在，脚本会默认复用它，不重复注册。

如果想丢开旧身份并重新注册：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | \
  FORCE_WARP_REGISTER=1 bash
```

## 只下载后再运行

如果你不想直接 `curl | bash`：

```bash
curl -fsSLO https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh
chmod +x install-sing-box-ss-warp.sh
./install-sing-box-ss-warp.sh
```

## 一键卸载

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | bash -s -- --uninstall
```

卸载会处理：

- 停用并卸载 `sing-box`
- 删除 SagerNet 软件源
- 删除 `/etc/sing-box` 和 `/var/lib/sing-box`
- 删除 `/usr/local/bin/wgcf`
- 删除 `/root/sing-box-wgcf`
- 删除 `/root/sing-box-ss-warp.txt`
- 删除脚本添加的 UFW 端口规则

如果想保留配置文件：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | KEEP_CONFIG=1 bash -s -- --uninstall
```

如果想保留 WARP profile：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | KEEP_WGCF=1 bash -s -- --uninstall
```

## 一键重启

WARP 出口由 `sing-box` 内置的 WireGuard endpoint 提供。WARP 连接异常时，重启 `sing-box` 会重建连接。

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | bash -s -- --restart
```

重启会做：

- 校验 `/etc/sing-box/config.json`
- 重启 `sing-box`
- 重新验证 direct / warp 的 TCP 和 UDP

脚本安装时也会配置 systemd 自动重启：

```text
Restart=on-failure
RestartSec=5s
```

## 常用文件

```text
/etc/sing-box/config.json             sing-box 配置
/root/sing-box-ss-warp.txt            节点信息
/root/sing-box-wgcf/wgcf-profile.conf WARP WireGuard profile
```

覆盖现有 `sing-box` 配置前，脚本会自动备份：

```text
/etc/sing-box/config.json.bak-YYYYmmdd-HHMMSS
```

## 查看状态

```bash
systemctl status sing-box --no-pager
ss -H -tulpen | grep sing-box
```

## 参数

常用环境变量：

```text
DIRECT_PORT=55221
WARP_PORT=36243
SS_METHOD=2022-blake3-aes-256-gcm
DIRECT_PASSWORD=<自动生成>
WARP_PASSWORD=<自动生成>
SERVER_IP=<自动检测>
WGCF_ARCH=<自动检测：amd64 或 arm64>
FORCE_WARP_REGISTER=0
RUN_VERIFY=1
DISABLE_WARP_SVC=1
INSTALL_UNATTENDED_UPGRADES=1  # 仅 Debian/Ubuntu 生效
KEEP_CONFIG=0                  # 卸载时使用
KEEP_WGCF=0                    # 卸载时使用
```

查看帮助：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | bash -s -- --help
```
