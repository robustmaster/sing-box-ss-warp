# sing-box-ss-warp

一键在 VPS 上安装 `sing-box`，同时提供两个 Shadowsocks 节点：

- `direct`：走 VPS 自己的公网 IP 出口。
- `warp`：走 Cloudflare WARP 出口。

两个节点都支持 TCP 和 UDP。WARP 不依赖 `warp-cli proxy`，而是使用 `sing-box` 自己的 WireGuard endpoint。

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
- 生成 Cloudflare WARP WireGuard profile
- 创建两个 Shadowsocks 入口
- 自动生成 Shadowsocks 密码
- 放行 UFW 的 TCP/UDP 端口，如果 UFW 已启用
- 配置自动更新
- 停用不再需要的 `warp-svc`
- 验证 direct / warp 的 TCP 和 UDP 是否可用

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

默认会复用已有的 WARP profile。

如果想重新注册：

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
FORCE_WARP_REGISTER=0
RUN_VERIFY=1
DISABLE_WARP_SVC=1
INSTALL_UNATTENDED_UPGRADES=1
```

查看帮助：

```bash
curl -fsSL https://raw.githubusercontent.com/robustmaster/sing-box-ss-warp/main/install-sing-box-ss-warp.sh | bash -s -- --help
```

