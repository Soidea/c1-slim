# C1-Slim —— 设备参考手册

**[English](HARDWARE.md) · [简体中文](HARDWARE.zh-CN.md)**

快易典 C1-Slim / MP-D261。全部内容都在真机上验证过，任何一份公开资料里都查不到。
未经验证的条目已单独标注。

---

## 1. 总览

一台 296 × 152 单色墨水屏设备，带全键盘，跑的是 Ingenic X1600 上的
**Buildroot Linux** —— 不是 Android。开箱即有 root 权限的 ADB。

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 小端 · 单核 · `cpufreq-dt` |
| 内存 | 64 MB（`mem=64M@0x0`） |
| 存储 | 64 GB eMMC —— 122 142 720 个 512 B 扇区 |
| 内核 | Linux 5.10.186 · Buildroot · SysV init · BusyBox |
| 屏幕 | SEEKINK E0266A128 · 296 × 152 · 1 bpp · 约 125 DPI · 60 × 31 mm |
| 键盘 | 40 键 —— 30 键矩阵（`event0`）+ 10 键 GPIO（`event1`） |
| LED | 4 颗 · led2/3 绿，led4/5 红 · 只有亮灭 |
| Wi-Fi | AltoBeam ATBM603x · SDIO `007A:6011` · 2.4 GHz b/g/n HT40 |
| 蓝牙 | **无** |
| 音频 | ALSA 声卡 `halley6`，codec ES8326 —— 麦克风、扬声器、3.5 mm 耳机孔 |
| 其他 | 电池 + AC/USB 检测 · RTC `/dev/rtc0` · 2 路 I²C · 1 路 UART |
| 没有 | 摄像头、振动马达、SPI、触摸 |

`halley6` 是 Ingenic 自己的 X1600 参考板名称，说明厂商基本照抄了参考设计 ——
Ingenic Halley6 的资料大概率适用。

### 1.1 「不是 Android」意味着什么

SysV init 脚本、BusyBox、直接用 ALSA、厂商字符设备而非 HAL。没有属性服务、
没有 `pm`、没有 ART、没有 APK。

唯一的 Android 组件是 **adbd**，从 AOSP 移植过来，至今仍报告 LG Nexus 4 的身份
（`product:occam model:Nexus_4 device:mako`，Android 4.2，2012 年）。后果是
**2012 年之后加入的 adb 特性全都没有** —— 尤其 `adb exec-out` 会直接
`error: closed`。用 `adb pull` / `adb push`。

---

## 2. 引导与恢复

### 2.1 引导链

```
BootROM（掩膜 ROM，在芯片里，擦不掉也写不坏）
└─ eMMC 用户区扇区 0 —— "INGE" 魔数
   └─ U-Boot SPL 2013.07
      └─ U-Boot        控制台 ttyS2 @ 1500000 8N1，bootdelay=1
         └─ kernel → /dev/mmcblk0p7（ext4，只读）→ C1ancher
```

出厂 `bootargs`：

```
console=ttyS2,1500000n8  rootfstype=ext4 root=/dev/mmcblk0p7 rootdelay=1 ro mem=64M@0x0
```

U-Boot 二进制里还有第二套，用 `root=/dev/ram0 rdinit=/linuxrc` ——
固件带了 initramfs 救援路径，只是默认不走。

### 2.2 分区表

| 区域 | 起始扇区 | 大小 | 挂载 |
|---|---|---|---|
| SPL + U-Boot | 0 | 3 MB | 裸区，**不是分区** |
| p1 | 6 144 | 9 MB | 未挂载，用途未知 |
| p2 | 24 576 | 16 MB | 未挂载，用途未知 |
| p3 | 57 344 | 16 MB | 未挂载，用途未知 |
| p4 | 90 112 | 68 MB | 未挂载，用途未知 |
| p5 | 229 376 | 200 MB | `/usr/resource` 读写 |
| p6 | 638 976 | 100 MB | `/usr/data` 读写 |
| p7 | 843 776 | 400 MB | `/` ext4 **只读** |
| p8 | 1 662 976 | 60 GB | `/storage` 读写 |

`mmcblk0boot0` / `boot1` 存在（各 4 MB）但**全是 0** —— eMMC 的硬件 boot 分区没有使用。
所有引导代码都在 p1 之前那 3 MB 空隙里，**按分区做的备份覆盖不到**。

### 2.3 整机镜像

扇区 0 – 1 662 975（**812 MiB**）包含了「让这台机器成为这台机器」的全部内容。
p8 是用户数据，不在其中。

```sh
adb shell 'dd if=/dev/mmcblk0 of=/storage/c1-system.img bs=1M count=812'
adb shell 'sha256sum /storage/c1-system.img'
adb pull /storage/c1-system.img .
shasum -a 256 c1-system.img            # 必须一致
head -c 4 c1-system.img | xxd          # 必须读出 INGE
adb shell 'rm /storage/c1-system.img'
```

### 2.4 BootROM USB 恢复模式 —— 已确认

X1600 的启动源由两根上电瞬间采样的 strap 脚决定。这块板子上**两根都接在按键上**，
这就是为什么反复试单个按键永远试不出来：

| Strap | GPIO | 按键 |
|---|---|---|
| BOOT_SEL0 | PC27 —— gpio-91，内核标注 `KEY_ENTER` | **回车** |
| BOOT_SEL1 | PC28 —— gpio-92，无驱动认领 | **返回** |

| boot_sel[1:0] | 启动源 | 本机表现 |
|---|---|---|
| `00` 不按键 | MSC0（eMMC） | 正常启动 |
| `01` 回车 | SFC0（SPI Flash） | 未配备 —— 起不来 |
| `10` 返回 | NOR | 未配备 —— 起不来 |
| `11` **返回 + 回车** | **USB** | **BootROM USB 恢复模式** |

按住**返回 + 回车**，再插 USB。设备枚举为：

```
idVendor  0xa108     Ingenic
idProduct 0xEAEF
product   "Ingenic USB BOOT DEVICE"
```

它在 U-Boot 之下、SPL 之下、eMMC 上一切之下，软件破坏不了它。
**进入这个模式不写任何东西** —— BootROM 只是在等主机跟它说话。

**主机侧尚未证实**：还没有在 macOS 上编出 cloner 工具并真正跟设备通信过，
读写路径未经验证。

### 2.5 怎么退出来 —— 进去之前先读

一旦进入 BootROM USB 模式：

- **拔 USB 退不出来。** 有内置电池，SoC 一直有电。
- **长按电源键退不出来。** 这里的关机是软件实现的，而此时没有内核在跑。
- **屏幕不能作为判断依据。** 墨水屏断电后仍保留最后一幅画面。

出路是**电源键旁边的复位孔** —— 捅一下就正常冷启动。没有它，唯一办法是耗光电池（数小时）。

### 2.6 U-Boot 的 `softburn`

U-Boot 里带了 `softburn` 命令（"Ingenic usb soft burn"），能从 U-Boot 提示符进入同一个
USB 烧录模式。但要拿到提示符就得接 UART：`ttyS2`，**1 500 000 波特率** ——
便宜转接板大多达不到，CH343P 和 FT232RL 可以，老款 CP2102 不行。既然「返回 + 回车」
能直接进 BootROM，`softburn` 在这里是多余的，**且从未实测**。
板子上是否引出了 UART 焊盘同样**未验证**（从未拆机）。

### 2.7 写入风险

| 目标 | 风险 | 怎么救 |
|---|---|---|
| 屏幕、LED、`/tmp`、`/dev/shm` | 无 | 重新上电 |
| p5、p6、p8 | 无 | 不参与启动 |
| p7 上的文件，含 `/etc/app_daemon` | 低 | 用 ADB 推回去 |
| `/etc/init.d/S90usb`、`/etc/init.d/usb/adb` | **高** | BootROM |
| p1–p4 | 未知 | BootROM |
| 扇区 0–6143、U-Boot 环境变量 | 高 | BootROM + 镜像 |

`app_daemon` 写坏了没关系：`S80app` 用 `&` 启动它后立即返回，而 adbd 是由
`S90usb` → `/etc/init.d/usb/adb` 单独拉起的。相应地，这两个文件绝对不能碰 ——
**它们是进入设备的唯一通道**。没有第二条：sshd 装了但起不来，因为 `ssh-keygen -A`
要往只读的 `/etc/ssh` 里写，而且 root 的密码字段是 `*`。

改 p7 的固定动作：`mount -o remount,rw /` → 改 → `sync` → `mount -o remount,ro /`。
设备**无法自行断电**（没有 `pm_power_off`），每次关机都是硬断，
**把 `/` 留在读写状态是这里最现实的丢数据方式**。

---

## 3. 显示

### 3.1 帧布局 —— 条带优先

```
byte = buf[(y >> 3) * 296 + x]
bit  = 7 - (y & 7)
1    = 黑
```

19 条横向条带，每条 8 像素高。每条是 296 个连续字节，一列一个；每字节装 8 个纵向堆叠的
像素，最高位在上。共 **5 624 字节**。

权威依据 —— `src/display/frame.c` 里的 `c1_display_frame_set_pixel()`：

```c
offset = (y / C1_DISPLAY_STRIP_HEIGHT) * C1_DISPLAY_WIDTH + x;
mask   = (uint8_t)(0x80U >> (y % C1_DISPLAY_STRIP_HEIGHT));
```

**陷阱**：列优先（296 × 19）和条带优先（19 × 296）都是 5 624 字节。尺寸校验分辨不出，
打包/解包往返测试也会通过，因为它自洽。要对着源码或真机验证，**绝不能对着自己的往返测试验证**。

### 3.2 一帧必须一次 `write()`

驱动把**每次 `write()` 都当作新一帧的开始**。分块写只会显示最后一块，落在左上角 ——
如果块边界没对齐条带，还会有横向偏移。

```sh
cat frame.bin > /dev/epaper_lcd                      # 错 —— 可能分多次写
dd if=frame.bin of=/dev/epaper_lcd bs=5624 count=1   # 对 —— 一次系统调用
```

### 3.3 刷新耗时 —— 实测

| 操作 | 屏幕耗时 | 说明 |
|---|---|---|
| 只写帧 | **约 150 ms** | 光是写入就会更新屏幕，不需要碰 sysfs |
| 写帧 + `echo 1 > refresh` | **约 700 ms** | 全刷，有可见的黑色反相闪烁 |

两种独立方法互相印证。**30 fps 录像数帧**：只写帧在 4–5 帧内稳定（133–167 ms，观察三次）；
`echo 1 > refresh` 产生 白 → **黑** → 白 共 21 帧（约 700 ms），黑色阶段就是清残影的波形。
**轮询 `refresh_cnt`**：670、670、680、680、670 ms（σ ≈ 5 ms）。旁证：C1ancher 的 README
把终端快刷写作「约 150 ms」，与实测快路径完全一致 —— 这个常数是从硬件量出来的。

**写 `refresh` 是非阻塞的**，10–20 ms 就返回，屏幕之后才更新。给这个系统调用计时什么也测不到。

`echo 0 > refresh` **未确认** —— 有一次观察像是快刷而非全刷，但只有单个样本。用 `1`。

### 3.4 `refresh_cnt` 不是完成计数器

可读、会变，但**不单调** —— 观察到 `30 → 31 → 1 → 3`，以及写入 `1` 后从 `6 → 31`。
结合 `refresh_max = 30`，它更像局刷周期计数器：累加，到上限强制全刷清残影，然后归零。
只能当全刷的粗略完成信号，**绝不能当帧计数器**。

### 3.5 显存读不回来

`/dev/epaper_lcd` 是只写字符设备（主 10，次 61），`read()` 返回 0 字节。没有 `/dev/fb*`。

要截图就给渲染器打补丁，把每帧旁路一份 ——
[`patches/display-shadow.patch`](patches/display-shadow.patch) 在成功写屏后把每帧写到
`/dev/shm/c1-screen.bin`（tmpfs，不磨损 eMMC），`adb pull` 下来就是像素级精确的截图。
代价是二进制体积 +4 字节。

### 3.6 sysfs

`/sys/devices/platform/e0266a128/epaper/`

| 属性 | 权限 | 说明 |
|---|---|---|
| `refresh` | `--w-------` | 写 `1` 触发全刷；非阻塞 |
| `refresh_cnt` | `-r--r--r--` | 周期计数器，不单调 |
| `refresh_max` | `-rw-r--r--` | `30` —— 强制全刷前的局刷次数 |
| `fast_refresh_only` | `-rw-r--r--` | 测试中写 `1` 会抑制全刷路径 |

### 3.7 对设计的影响

真正的约束是**刷新耗时，不是分辨率或色深**。静态内容零成本且永久保持，改像素才要钱。

- 审批卡、状态页、速查表 → 用全刷。700 ms 换一幅干净无残影的画面，决策提示不需要更快。
- 终端和持续输出 → 只写帧，不碰 `refresh`。约 150 ms，且调用 10–20 ms 就返回，不会卡住循环。
- 预期会有周期性的约 700 ms 顿挫：大约 `refresh_max` 次局刷后驱动会强制全刷。
- **需要「即时感」的东西交给 LED。** GPIO 写入是瞬时的，屏幕不是。屏幕回答「是什么」，
  LED 回答「有没有」。
- 152 = 19 × 8 正好，所以任何纵向起点是 8 的倍数的元素都能退化成纯字节拷贝。
  不对齐就得移位加掩码。
- 一条 1 px 横线要碰 296 个字节；一条 1 px 竖线只碰一个条带里的 19 个字节。
  **纵向元素便宜得多。**
- UI 用**有序抖动（Bayer），不要误差扩散**。有序图案空间固定，内容小改只翻转真正变化的
  像素；Floyd–Steinberg 会把整片区域重新随机化，残影很重。照片仍然该用误差扩散。
- 约 125 DPI 下 1 px 线宽约 0.2 mm，是发丝线而不是锯齿边。这块屏能承载的细节比
  72 DPI 的老 Mac 审美所暗示的要精细得多。

### 3.8 直接写屏时

C1ancher 占着显示并周期性重绘，会覆盖你写的一切：

```sh
adb shell '/etc/init.d/S80app stop'
# ... 你的写入 ...
adb reboot
```

---

## 4. 输入

完整 26 字母 QWERTY，外加 Shift、空格、回车、Delete、方向键、返回、OK、Home、唤醒和音量键
—— 30 个矩阵键在 `/dev/input/event0`，10 个 GPIO 键在 `event1`。扫描码见
[`config/c1-slim/keyboard.csv`](config/c1-slim/keyboard.csv)。

C1ancher 把「按住 OK + 字母」映射为 Ctrl+A–Z，OK 单击为 Tab，返回键为 Esc ——
足以在它自带的终端里驱动 `vi`、`top`、`less` 和交互式 `ssh`。

### 4.1 GPIO 按键映射（Port C）

引脚电平可在寄存器 `0x10010200` 实时读取，boot strap 就是这么定位到的：

```sh
adb shell 'while true; do busybox devmem 0x10010200; sleep 0.1; done' | awk '!seen[$0]++'
```

| 位 | GPIO | 按键 | 备注 |
|---|---|---|---|
| 0 | PC0 | Emoji（Home） | |
| 1 | PC1 | Shift | |
| 2 | PC2 | 音量减 | |
| 26 | PC26 | — | `sdio_power`，随 Wi-Fi 变化 |
| **27** | **PC27** | **回车** | **BOOT_SEL0** |
| **28** | **PC28** | **返回** | **BOOT_SEL1** |
| 31 | PC31 | 电源 | 低电平有效 |

`/sys/kernel/debug/gpio` 里的其他标注（需先挂 debugfs）：`matrix_kbd_row/col`、
`lcd-reset/dc/busy/cs/sdi/sck`、`up/down/left/right/ok`、`DELETE`、`key_p`、
`wifi_reset`、`led2`–`led5`、`ingenic,audio-select`、`charge_stat`、`vbus_detect`、
`ingenic,spken`。

---

## 5. LED

4 颗，走标准 Linux LED 类，在 `/sys/class/leds/` 下，来自厂商的 `mpen,gpio-leds` 节点。

| 节点 | 颜色 |
|---|---|
| `led2`、`led3` | 绿 |
| `led4`、`led5` | 红 |

`max_brightness` 读出 `255`，但**没有 PWM** —— 8、32、96、255 看起来一模一样。当二值用。

表现力来自内核触发器，零 CPU 开销：

```
none  timer  oneshot  heartbeat  mtd  nand-disk  mmc0  mmc1
battery-charging  battery-full  battery-charging-or-full
battery-charging-blink-full-solid  ac-online  usb-online
rfkill-any  rfkill-none  kbd-*lock
```

`timer` 通过 `delay_on` / `delay_off`（毫秒）给出任意闪烁频率；`oneshot` 按需闪一次；
`heartbeat` 跟随 CPU 负载。**`timer` 触发器会覆盖手动写 `brightness`** —— 先设成 `none`：

```sh
echo none > /sys/class/leds/led4/trigger
echo 255  > /sys/class/leds/led4/brightness
```

至少有一颗 LED 默认挂在充电触发器上（关机充电时亮红），接管之前先记下原本的 `trigger`。

---

## 6. 无线

**AltoBeam ATBM603x**，SDIO，模块 `atbm603x_wifi_sdio.ko`（818 KB，厂商二进制）。

```
SDIO_ID=007A:6011   DRIVER=atbm_wlan   MODALIAS=sdio:c00v007Ad6011
```

**按需加载** —— 默认没有 `wlan0`，`/proc/modules` 是空的，射频处于完全不供电状态。
厂商提供 `/bin/wifi_up.sh` 和 `/bin/wifi_down.sh`；`wifi_up.sh` 会 `insmod`、等 `wlan0`、
然后用**原厂**配置 `/usr/resource/wpa_supplicant.conf` 启动 `wpa_supplicant` ——
而 C1ancher 用的是自己的 `/usr/data/c1/wifi/wpa_supplicant.conf`，两者别混用
（手动跑过 `wifi_up.sh` 之后重启一次）。

模块路径是 `.../atbm_wifi_40M/hal_apollo/`。"Apollo" 是 ST-Ericsson **CW1200** 的代号，
所以这个驱动是 CW1200 的衍生版 —— 主线的 `drivers/net/wireless/st/cw1200/` 是它的远亲。

### 6.1 没有蓝牙

四项独立的否定检查：没有 `/sys/class/bluetooth`、没有 `/proc/net/bluetooth`
（内核没编 BT 协议栈）、`/proc/devices` 里没有、没有 `hci*` 节点。整个系统里只有两个内核
模块：Wi-Fi 驱动和一个 netfilter 模块。

ATBM6031 官方数据手册也没有蓝牙。同系列较新的型号（ATBM6012B-X、6132、6162）是 BLE 5.0
二合一，但这里的 SDIO ID 是 `6011`，最基础的一档。就算硅片上有射频，内核也还需要 BT 栈、
HCI 传输和固件 —— 一样都没有。

---

## 7. 音频

```
card 0: halley6
  capture  device 0: i2s-ecodec es8326.1-0018-0    （I²C 总线 1，地址 0x18）
  capture  device 1: i2s-tloop dump_pcm_codec-1
  playback device 0: i2s-ecodec es8326.1-0018-0
```

麦克风、扬声器和 3.5 mm 耳机孔都可用。混音器控件包括 `Analog Headphone`、
`Speaker Enable`、`ADC PGA Gain`、`ALC …`、`DRC …`。耳机检测以 Android 风格暴露在
`/sys/class/switch/h2w/state`（0 = 无，1 = 带麦耳机，2 = 普通耳机）。

```sh
arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav
```

16 kHz 单声道 S16LE 正是语音识别的标准输入格式，麦克风可以不经重采样直接喂给 ASR。

对一段普通说话录音的实测：峰值 −0.83 dBFS，RMS −23.7 dBFS，波峰因数 22.8 dB。
波峰因数落在语音的正常区间，但峰值离削波不到 1 dB —— **录音增益开得非常猛**。
在意 ASR 准确率的话用 `amixer -c 0` 压一压，削波比电平低危害大得多。
`scripts/device-control.sh` 用 `alsactl … 0` 保存和恢复混音器状态。

---

## 8. 电源

`/sys/class/power_supply/` 暴露 `battery`、`ac`、`usb`。电池报告 `status`、`capacity`、
`voltage_now`（满电 4.192 V）；没有 `current_now`，没有 `temp`。硬件 RTC 在 `/dev/rtc0`；
`cpufreq-dt` 存在，支持调频。

**这台设备无法自行断电。** `poweroff`、`halt`、`poweroff -f` 都能跑完，但电源纹丝不动 ——
这块板子没有 `pm_power_off`。长按关机也是软件实现的，所以没有内核在跑时同样无效。
唯一的硬件级断电是**电源键旁边的复位孔**。

关机状态插 USB 只充电、不启动（红灯来自 `battery-charging` 触发器）。

---

## 附录 A —— 我们试过什么，包括失败的

按确立顺序记录的否定结果。之所以写下来，是因为每一条都花掉了一轮调试，
而且每一条都堵死了一条看起来很合理的路。

| 尝试 | 结果 |
|---|---|
| 从 VID `18D1` + ADB + MTP 推断是 Android | **错** —— 是 Buildroot，只有 adbd 来自 AOSP。`pm`、Launcher 那套建议全部不适用 |
| 按列优先打包帧缓冲 | **错** —— 两种布局都是 5 624 B，尺寸校验和自洽的往返测试都通过；真机上显示成竖条纹 |
| `cat frame.bin > /dev/epaper_lcd` | **错** —— 每次 `write()` 都是新一帧，只显示最后一块 |
| 给 `refresh` 系统调用计时 | **错了 50 倍** —— 写 `refresh` 是非阻塞的 |
| `adb exec-out` | 2012 年代的 adbd 不支持（`error: closed`） |
| 把测试帧写到 `/tmp` | `/tmp` 是 tmpfs，`adb reboot` 后就没了 |
| C1ancher 还跑着就写屏 | 它会重绘覆盖你 |
| C1ancher Makefile 用 `make -j4` | 竞态 —— host-test 会在 libtsm 目标文件之前链接。用 `-j1` |
| 手写 5 × 7 点阵字体 | g/p/q 字形不对。换成 Ark Pixel Font（OFL-1.1），从 PNG 字形源烘焙 |
| `poweroff`、`halt`、`poweroff -f` | 全部无效 —— 没有 `pm_power_off` |
| 上电时按住单个键（Home、电源、Home+电源、摇杆+电源） | 进不了恢复模式。两根 strap 都是按键，只有**组合**才行 |
| 上电时只按住返回键 | 设备不启动 —— `boot_sel = 10` = NOR，未配备。看着像故障，其实不是 |
| `cat /sys/kernel/debug/gpio` | 挂 debugfs 之前是空的：`mount -t debugfs none /sys/kernel/debug` |
| `cat /proc/iomem \| grep -i gpio` | 空的 —— GPIO 没在那里登记。用 debugfs |
| 以为 sshd 是可用的第二通道 | 不是 —— 没有 host key（`/etc/ssh` 只读），root 密码字段是 `*` |
| 计划加一个早期的 `S15adbd` 保险脚本 | 否决 —— `S90usb` 是一整套 configfs gadget 流程，复制一份会互相打架，而改它就是在改唯一的入口 |
| 拔 USB / 长按电源以退出 BootROM | 都无效 —— 有内置电池、关机是软件实现的。**复位孔**才是出口 |

### 主机侧的坑

- shell 脚本里，变量后紧跟非 ASCII 字符时要写 `${VAR}` 而不是 `$VAR`。bash 会把 UTF-8
  前导字节吃进标识符，`set -u` 下报 `VAR?: unbound variable`。这个坑踩了两次。
- `local a="$1" b=$((...))` 会在赋值前展开所有参数 —— 拆成两句，否则 `set -u` 下直接死。
- zsh 交互模式**默认不把 `#` 当注释**（除非 `setopt interactive_comments`），
  粘贴带注释的命令块会报 `command not found: #`。
- 墨水屏断电后仍显示最后一幅画面，所以**屏幕永远不能作为设备状态的证据**，要看 USB 枚举。

### 仍未验证

- p1–p4 的用途
- `echo 0 > refresh` 的语义
- 板子上是否引出了可接触的 UART 焊盘
- `softburn` —— 命令在 U-Boot 镜像里，但从未执行过
- BootROM 的主机侧：还没有编出 cloner 工具跟设备通信过
- 目视数到的第 5 颗灯，与 sysfs 里的 4 颗 LED 的差异
- I²C 总线上挂了什么

---

## 附录 B —— 速查

```sh
# 屏幕
adb shell '/etc/init.d/S80app stop'
adb push frame.bin /tmp/f.bin
adb shell 'dd if=/tmp/f.bin of=/dev/epaper_lcd bs=5624 count=1'
adb shell 'echo 1 > /sys/devices/platform/e0266a128/epaper/refresh'

# 截图（需已打补丁的固件）
adb pull /dev/shm/c1-screen.bin

# LED
adb shell 'echo none > /sys/class/leds/led4/trigger; echo 255 > /sys/class/leds/led4/brightness'

# GPIO / 按键探测
adb shell 'mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/gpio'
adb shell 'while true; do busybox devmem 0x10010200; sleep 0.1; done' | awk '!seen[$0]++'

# 音频
adb shell 'arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav'

# 整机备份 —— 见 2.3
# BootROM 恢复 —— 按住 返回 + 回车 再插 USB；用复位孔退出
```

---

## 附录 C —— 相关项目

针对这台设备本身的生态基本只有 C1ancher，但
**Ingenic X1600 + AltoBeam ATBM603x 正是国产 IP 摄像头的标准 BOM**，那个社区的工具链直接适用：

- [gtxaspec/atbm-wifi](https://github.com/gtxaspec/atbm-wifi) —— 这一系列 Wi-Fi 的开源驱动
- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) —— 内核树，X1600 标注为部分支持
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) —— XBurst1 的 U-Boot
- [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) —— X2000E 的 usbboot，最接近 X1600 的现代兄弟
- [gcwnow/ingenic-boot](https://github.com/gcwnow/ingenic-boot) —— 老 XBurst 的 USB boot 工具
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) —— USB DFU / Ingenic Cloner 刷写工具
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) —— 各 SoC 的 cloner 触发方式
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) —— 规模较大的 Ingenic 固件社区

XBurst1 的 U-Boot 和 AltoBeam 的 Wi-Fi 驱动是同一个维护者发布的 ——
这不是巧合，是同一套硬件平台。
