# tools

主机端工具，配合 [`../HARDWARE.md`](../HARDWARE.md) 使用。

| 文件 | 用途 |
|---|---|
| `c1gfx.py` | 帧打包/解包。图片 ↔ 5624 字节设备帧，含抖动 |
| `arkpix.py` · `arkpix_data.py` | 点阵文字渲染，10/12/16px 三档 |
| `bake_font.py` | 从 Ark Pixel Font 字形源重新烘焙 `arkpix_data.py` |
| `approval.py` | 示例：生成审批卡片帧 |
| `push-card.sh` | 把 5624 字节帧推到屏上（用 `dd` 保证单次 write） |
| `grab-screen.sh` | 截图（需先打 `../patches/display-shadow.patch`） |
| `measure-refresh.sh` | 用 `refresh_cnt` 客观测量刷新耗时 |

## 快速上手

```bash
pip3 install pillow            # macOS 可能需要 --break-system-packages --user
python3 approval.py            # 生成 card-*.bin 和预览图
./push-card.sh --stop card-03-high.bin
./grab-screen.sh
```

## 字体

点阵文字用 **[Ark Pixel Font 方舟像素字体](https://github.com/TakWolf/ark-pixel-font)**
（TakWolf，OFL-1.1，见 `LICENSE-OFL`）。

选它是因为它的字形源本身就是逐字 PNG 位图，`bake_font.py` 直接读像素，
跳过 TrueType 栅格化——避免了"抗锯齿后阈值化导致笔画时粗时细"的问题。

三档等宽字号按原生尺寸使用，需要更大时只做**整数倍**放大
（每个原始像素变成 N×N 实心方块，笔画依然均匀）。非整数倍会引入半像素。
