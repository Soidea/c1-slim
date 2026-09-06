# 在 Apple Silicon Mac 上刷入 C1ancher

**[English](MACOS.md) · [简体中文](MACOS.zh-CN.md)**

快易典 C1-Slim / MP-D261（Ingenic X1600 电子纸设备）的 C1ancher 工具链 macOS 移植。
不需要 Windows、WSL、Docker，也不需要拆机。

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 小端 |
| 内核 | Linux 5.10.186（Buildroot） |
| 面板 | SEEKINK E0266A128 · 296 × 152 · 1 bpp · 约 125 DPI |
| 显存 | 5,624 字节（按列存储，每列 19 字节） |

> **仅限本人拥有的设备。** 常驻 ADB 装好之后，**任何**电脑插上 USB 都直接获得 root
> shell，没有授权提示。这是上游项目明确选择的开放开发模式，不是疏漏。

---

## 原理

整个过程不碰固件、不写分区、不解 bootloader。

设备的「关于设备」页面有一个隐藏入口。触发后，设备会向厂商接口发出一个 HTTPS 请求：

```
GET /v1/pens/{penId}?action=adbAdmit&random={数字}
Host: api.mpen.com.cn
```

固件的网络库关闭了证书链和主机名校验，所以一次性自签名证书就能在本地完成 TLS。
我们在 Mac 上精确截获这一个请求，自己回一个成功响应：

```json
{"errorCode":"200","errorMsg":"","data":{"success":true}}
```

`errorCode` 必须是**字符串** `"200"`。数字 `200` 或 `0` 都不会被这个固件接受——
即使日志显示响应已发送。

设备随后重建 USB gadget 并暴露 ADB。之后所有操作都通过普通的 root ADB shell 完成，
根文件系统全程保持只读。

### macOS 移植与 Windows 原版的差异

| Windows 原版 | macOS 移植 |
|---|---|
| WinDivert 抓包 + 注入 | pf `rdr` 重定向，锚点 `com.apple/c1slim-adb` |
| Windows 移动热点 | 系统设置 → 共享 → 互联网共享 |
| `New-NetFirewallRule` | 限定单一来源 IP 的 pf 规则 |
| `Get-NetNeighbor` 发现设备 | `/var/db/dhcpd_leases` + `arp -an` |
| WSL 交叉编译 | Docker/Podman 容器（或直接用 `prebuilt/`） |
| `*.ps1` | `macos/*.sh` |

pf 方案比 WinDivert 更干净：内核完成 NAT 并在回程自动反向转换，
所以原版里手工改写响应源地址的那一套完全不需要。

---

## 环境准备

```bash
brew install --cask android-platform-tools
pip3 install cryptography
chmod +x macos/*.sh
```

macOS 不需要任何 ADB 驱动，设备的 `VID_18D1` 会直接枚举。

准备一根**支持数据传输**的 USB-C 线。充电线是 `adb devices` 返回空最常见的原因。

---

## 第 0 步 — 开启互联网共享

设备必须连接**这台 Mac 发出的**热点。整个方法依赖设备流量经过 Mac，
所以还连着家里路由器的设备永远不会触发成功。

**系统设置 → 通用 → 共享 → 互联网共享**：共享来源选你的上网接口，
「用以下端口共享给电脑」勾选 **Wi-Fi**，在「Wi-Fi 选项」里设好名称和 WPA2 密码，然后打开。

> **Apple Silicon 注意：** 单张网卡同时「连 Wi-Fi 上网」和「发 Wi-Fi 热点」
> 经常不稳定甚至起不来。可靠的组合是**上网走 USB-C 转以太网，共享给 Wi-Fi**。

Mac 会出现 `bridge100` 接口，网关通常是 `192.168.2.1`。把 C1-Slim 连上这个热点。

## 第 1 步 — 环境自检

`doctor.sh` 只读，不改任何东西。它逐项检查前置条件，并且——这一点很关键——
**列出热点上的所有客户端**，你的设备 MAC 就在这份列表里。
脚本里的默认 MAC 是原作者那台机器的，不是你的。

```bash
./macos/doctor.sh
```

认不出哪个客户端是 C1-Slim？把它的 Wi-Fi 关掉再跑一次，消失的那一行就是。

## 第 2 步 — 临时打开 ADB

```bash
sudo python3 macos/c1-adb-admit-macos.py --device-mac 58:C5:87:XX:XX:XX
```

等这三行全部出现。**看到 `READY` 之前不要碰设备**——
脚本保证 HTTPS 监听先就绪、重定向后开启，所以第一个 SYN 不可能早于监听器到达。

```
HTTPS_READY    address=192.168.2.1:8443 ...
PF_RULE_LOADED anchor=com.apple/c1slim-adb ...
READY open About-device and press Enter 10 times within 5 seconds
```

然后在设备上：

1. 打开**「关于设备」**
2. 把焦点停在显示**静态版本信息**的那一项上
3. 约 5 秒内，按下并**完整松开**全键盘 `Enter` 共 **10 次**

固件按**松开**事件计数，所以每次必须完整按下再松开，而且不能太慢。

**不要**执行 `C → S → Enter`——那个组合进的是 GCTest，与 ADB 无关。

成功后日志出现 `TLS_OK` 和 `APPROVED`，设备重建 USB gadget，
macOS 会记录一次 USB 断开重连。验证：

```bash
adb kill-server && adb start-server
adb devices -l          # 期望：MagicPen-xxxxxx  device
adb shell id            # 期望：uid=0(root) gid=0(root)
```

这个 ADB 只在**当前开机周期**有效。第 4 步让它常驻。

常用覆盖参数：

```bash
--device-ip 192.168.2.5           # 跳过 MAC 查找
--bridge bridge100                # 指定接口
--gateway-ip 192.168.2.1          # 覆盖网桥地址
--origin-ip 39.98.109.39          # 覆盖解析出的接口 IP
--keep-running                    # 保持运行，Ctrl-C 停止
```

## 第 3 步 — 整机备份 ⚠️

**别跳过。** 新机器手上没有原厂系统镜像，而第 6 步的 `remove-original`
在设备端**没有恢复路径**。这份备份是唯一的退路。

```bash
./macos/backup.sh              # 512 MB 以下的分区
./macos/backup.sh --all        # 全部分区
./macos/backup.sh --max-mb 2048
```

全程只读。导出分区表、启动脚本和分区镜像到 `~/C1Slim-Backup/<时间戳>/`，
并生成 `SHA256SUMS` 清单。

**继续之前，把这个目录复制到另一块盘。**

```bash
cd ~/C1Slim-Backup/<时间戳> && shasum -a 256 -c SHA256SUMS
```

## 第 4 步 — 让 ADB 开机常驻

原厂 `/etc/init.d/S90usb` 里本来就有一行 ADB FunctionFS 启动项，只是被注释掉了。
这一步把它取消注释。

```bash
./macos/install-open-adb.sh install --reboot
```

与 PowerShell 原版不同，**这里不需要固件解包目录**。原始 `S90usb` 直接从设备
`adb pull` 下来，比对已知哈希 `c2b278b2…` 之后才做那一行修改。
安装器写入前后都做校验，失败时自动恢复原文件并把 `/` 重新挂载为只读。
副本保留在 `/etc/init.d/S90usb.c1-original`、`/usr/data/c1/recovery/open-adb/`
和 `/storage/c1/recovery/open-adb/`。

```bash
./macos/install-open-adb.sh verify    --reboot
./macos/install-open-adb.sh uninstall --reboot
```

## 第 5 步 — 安装 C1ancher

```bash
./macos/install-default-app.sh install --reboot
```

部署 C1ancher、`app_daemon` supervisor shim、Neofetch 7.1.0，
并为这台设备生成独有的 Ed25519 SSH host key。
设备端脚本逐文件 SHA-256 校验，失败自动回滚。
`--reboot` 会验证冷启动选择和单实例状态。

安装的 shim 与 PowerShell 安装器写入的**逐字节一致**
（LF、无 BOM、无结尾换行，SHA-256 `676a57aa…`），
所以两个平台装出来的设备状态完全相同。

现在设备是 C1ancher 的 3×3 九宫格首页：上 **WI-FI**、左 **SSH**、右 **TERMINAL**、
下 **DEVICE**（自动运行 neofetch）。四角显示 Wi-Fi 状态、SSH 状态、电量和时间。
原厂软件仍在磁盘上。

## 第 6 步 — 删除原厂软件（可选，不可逆）

```bash
./macos/install-default-app.sh remove-original --reboot
```

删除 `/usr/bin/d261`。设备端**没有恢复路径**，恢复需要第 3 步导出的镜像。
先确认备份通过 `shasum -c` 且已存放在第二块盘上。
不做这一步在功能上没有任何损失。

---

## 从源码构建

`prebuilt/` 里是已经交叉编译并通过 ABI 校验的二进制：

| 文件 | SHA-256 |
|---|---|
| `C1ancher` | `a031cceaadf85d2270c478713933ddbe51a9696b838ca5e053b03f260f48d6bf` |
| `C1ancher-launcher` | `d8ee229bbeb0b9cdebc5358ba55066b405e4656e33f444acae6af904fb4b394b` |

ELF32 · 小端 · o32 · mips32r2 · hard-float double · 完全静态链接。

复制到 `build/` 即可使用，或者自己复现：

```bash
./macos/build.sh                 # Docker 或 Podman
./macos/build.sh --engine podman
```

Debian 为 arm64 主机提供 `gcc-mipsel-linux-gnu`，所以在 Apple Silicon 上是原生编译，
不需要任何模拟。脚本会先跑上游的 host 测试，再执行与 `build.ps1` 相同的
ABI 和键盘映射校验。

---

## 排错

| 现象 | 处理 |
|---|---|
| `no active Internet Sharing bridge found` | 共享没开，或 `bridge100` 没拿到 `inet`。检查 `ifconfig bridge100`；用 `--bridge` / `--gateway-ip` 手动指定。 |
| `MAC ... was not found` | 设备没连 Mac 热点。报错会列出实际看到的客户端，照着传 `--device-ip`。DHCP 地址会变，别硬编码。 |
| 出了 `READY` 但没有 `TCP_ACCEPT` | 确认设备连的是 Mac 热点；确认焦点在静态版本信息项上；10 次按键要在约 5 秒内完成且每次完整松开。 |
| 出现 `APPROVED` 但设备仍拒绝 | 响应体必须保持字符串型错误码 `{"errorCode":"200",…}`，不要修改。 |
| `adb devices` 为空 | 换支持数据的 USB-C 线，换端口，然后 `adb kill-server && adb start-server`。 |
| `Open root ADB startup hash changed` | 第 5 步要求先完成第 4 步。先跑 `install-open-adb.sh install --reboot`。 |
| pf 规则没生效 | `sudo pfctl -s info \| head -1` 应为 Enabled；`/etc/pf.conf` 需含 `rdr-anchor "com.apple/*"`（macOS 默认自带）。 |
| pf 规则残留 | `sudo pfctl -a com.apple/c1slim-adb -F all` |

### 日志隐私

`macos/adb-admit-plaintext.log` 记录 TLS 解密后的完整 HTTP 请求，
可能包含 Cookie、手机号、`sessionId`、`penId`、设备序列号和内网地址。
**分享前务必删除这些字段**，排障结束后删掉日志。

---

## 回滚

| 目标 | 命令 |
|---|---|
| 关闭常驻 ADB | `./macos/install-open-adb.sh uninstall --reboot` |
| 清理残留 pf 规则 | `sudo pfctl -a com.apple/c1slim-adb -F all` |
| 恢复原厂启动器 | 需要第 3 步导出的镜像 |

停止 Mac 端脚本不会关闭设备当前开机周期内的 ADB。
要确认恢复默认状态：拔掉 USB，重启设备，重新插上，执行 `adb devices -l`。

---

## 相关项目

针对这台设备本身的生态很小，但 **SoC** 的生态不小。
X1600 属于 XBurst1，所以下面这些是对的家族：

- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) — 内核树，X1600 标注为部分支持
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) — XBurst1 的 U-Boot
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) — USB DFU / Ingenic Cloner 刷写工具
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) — 各 SoC 的 cloner 触发方式
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) — 规模较大的 Ingenic 固件社区（IP 摄像头方向）

如果 X1600 的 BootROM 暴露了 Cloner USB 恢复模式，那么写坏 eMMC 也能救回来，
动 U-Boot 的风险评估就完全不同了。深入之前值得先把这一点确认下来。
