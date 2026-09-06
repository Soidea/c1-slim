# C1-Slim 硬件笔记

**[English](HARDWARE.md) · [简体中文](HARDWARE.zh-CN.md)**

直接驱动设备过程中的发现，全部在真机上验证过。每一条都是撞上去才知道的，
在能找到的任何资料里都没有。

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 小端 · 单核 |
| 内核 | Linux 5.10.186（Buildroot） |
| 面板 | SEEKINK E0266A128 · 296 × 152 · 1 bpp · 约 125 DPI · 60 × 31 mm |
| 音频 | ALSA 声卡 `halley6`，codec **ES8326** —— 录放都有 |
| 键盘 | 40 键：30 矩阵键（`/dev/input/event0`）+ 10 GPIO 键（`/dev/input/event1`） |
| ADB | adbd 自报 `product:occam model:Nexus_4 device:mako` |

`halley6` 是 Ingenic 官方 X1600 开发板的名字，说明厂商基本照着参考设计做，
Ingenic 的 Halley6 资料很可能直接适用。

---

## 显示

### 帧布局 —— 条带优先，不是列优先

```
byte = buf[(y >> 3) * 296 + x]
bit  = 7 - (y & 7)
1    = 黑
```

整帧分成 19 条 8 像素高的横带。每条带是 296 个连续字节、每列一个；
一个字节装该带内垂直相邻的 8 个像素，最高位对应最上面那个。

权威依据是 `src/display/frame.c` 里的 `c1_display_frame_set_pixel()`：

```c
offset = (y / C1_DISPLAY_STRIP_HEIGHT) * C1_DISPLAY_WIDTH + x;
mask   = (uint8_t)(0x80U >> (y % C1_DISPLAY_STRIP_HEIGHT));
```

**这里有个坑：** 列优先（296 列 × 19 字节）和条带优先（19 带 × 296 字节）
总字节数都是 5624。尺寸校验分辨不出来，而打包/解包的往返测试因为自洽，
两种排法都能通过。我们曾经用列优先实现，所有测试全绿，推到设备上是竖条纹乱码。
**要对着源码或真机验证，不能只对着自己的往返测试。**

### `/dev/epaper_lcd` 必须单次 `write()` 写完

驱动把**每次 `write()` 调用都当作一帧的开头**。分块写的结果是只有最后一块留在屏上，
从左上角开始画。

```sh
# 错误 —— cat 可能分多次写，帧尾内容会跑到屏幕顶部；
#         如果分块边界不是整带对齐，还会横向错位
cat frame.bin > /dev/epaper_lcd

# 正确 —— 一次系统调用写满 5624 字节
dd if=frame.bin of=/dev/epaper_lcd bs=5624 count=1
```

C1ancher 自己没这个问题，因为它老老实实做了一次 `write(fd, frame, 5624)`。

### 显存读不回来

`/dev/epaper_lcd` 是只写字符设备（major 10，minor 61）：`read()` 未实现，返回 0 字节。
设备上也不存在 `/dev/fb*`。

要截图只能改渲染层加旁路 —— 见
[`patches/display-shadow.patch`](patches/display-shadow.patch)，
它在每次成功写屏后把同一帧另存到 `/dev/shm/c1-screen.bin`（tmpfs，不磨损 eMMC）。
`adb pull` 下来就是像素级精确的截图。

### sysfs

`/sys/devices/platform/e0266a128/epaper/`

| 属性 | 权限 | 说明 |
|---|---|---|
| `refresh` | `--w-------` | 写 `0` 触发刷新 |
| `refresh_cnt` | `-r--r--r--` | 单调递增计数器 —— 可用来客观测量刷新耗时 |
| `refresh_max` | `-rw-r--r--` | 驱动刷新策略上限 |
| `fast_refresh_only` | `-rw-r--r--` | `1` 表示只用快刷（局部波形） |

### 对设计的影响

真正的约束是**刷新耗时，不是分辨率也不是色深**。静态内容免费且永久，
改变像素才有代价。

- 152 = 19 × 8 整除，所以任何起点落在 8 的倍数上的元素，blit 就是纯字节写入；
  不对齐则需要移位加掩码。
- 一条 1px 水平线要碰 296 个字节；一条 1px 垂直线只碰单个条带内的 19 个字节。
  **垂直元素便宜得多。**
- UI 用**有序抖动（Bayer），不要用误差扩散**。有序图案空间固定，内容小改只翻转
  真正变化的像素；Floyd–Steinberg 会整片重新随机化，在电子纸上表现为大面积残影。
  照片仍然适合误差扩散。
- 约 125 DPI 下 1px 线宽约 0.2mm，读起来是**发丝线**而不是锯齿。
  这块屏能承载的精细度比"72 DPI 经典 Mac"的印象要高。

---

## 音频

```
card 0: halley6
  capture  device 0: i2s-ecodec es8326.1-0018-0
  capture  device 1: i2s-tloop dump_pcm_codec-1
  playback device 0: i2s-ecodec es8326.1-0018-0
```

麦克风和喇叭都可用。已验证的录音命令：

```sh
arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav
```

16 kHz 单声道 S16LE 正是各家 ASR 引擎的标准输入格式，不需要重采样。

一段普通人声实测：峰值 −0.83 dBFS，RMS −23.7 dBFS，波峰因数 22.8 dB。
波峰因数落在语音的正常区间（而非底噪区间），但峰值离削波不到 1 dB
—— **录音增益开得很猛**。在意 ASR 准确率的话用 `amixer -c 0` 压一点，
削波比音量小影响大得多。

`scripts/device-control.sh` 里有用 `alsactl … 0` 做混音器状态快照和恢复的例子。

---

## 键盘

完整 26 键 QWERTY，外加 Shift、Space、Enter、Delete、方向键、Back、OK、Home、
Wakeup 和音量键。C1ancher 把 OK 长按 + 字母映射成 Ctrl+A–Z，OK 单击为 Tab，
Back 为 Esc —— 足以在它内置的终端里驱动 `vi`、`top`、`less` 和交互式 `ssh`。

扫描码见 [`config/c1-slim/keyboard.csv`](config/c1-slim/keyboard.csv)。

---

## 相关项目

针对这台设备本身的生态基本只有 C1ancher，但 **SoC** 的生态不小。
X1600 属于 XBurst1，下面这些是对的家族：

- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) —— 内核树，X1600 标注为部分支持
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) —— XBurst1 的 U-Boot
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) —— USB DFU / Ingenic Cloner 刷写工具
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) —— 各 SoC 的 cloner 触发方式
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) —— 规模较大的 Ingenic 固件社区

如果 X1600 的 BootROM 暴露了 Cloner USB 恢复模式，那么写坏 eMMC 也能救回来，
动 U-Boot 的风险评估就完全不同。**这台设备上尚未验证** —— 深入之前值得先确认。
