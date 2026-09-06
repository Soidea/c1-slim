#!/usr/bin/env bash
# 把 5624 字节的帧推到 C1-Slim 屏幕上。
#
#   ./push-card.sh card-03-high.bin            # 直接推（C1ancher 可能随后重绘覆盖）
#   ./push-card.sh --stop card-03-high.bin     # 先停掉 C1ancher，画面会一直留着
#   ./push-card.sh --stop card-03-high-inv.bin # 如果屏幕显示成负片，用 -inv 版本
#
# 恢复：adb reboot   （最稳，一定能回到 C1ancher）

set -euo pipefail
EPAPER=/dev/epaper_lcd
SYSFS=/sys/devices/platform/e0266a128/epaper
STOP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop) STOP=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) FRAME="$1"; shift ;;
    esac
done

[[ -n "${FRAME:-}" ]] || { echo "用法: $0 [--stop] <frame.bin>" >&2; exit 2; }
[[ -f "$FRAME" ]] || { echo "找不到文件: $FRAME" >&2; exit 1; }

SIZE=$(stat -f%z "$FRAME" 2>/dev/null || stat -c%s "$FRAME")
[[ "$SIZE" -eq 5624 ]] || { echo "帧大小应为 5624 字节，实际 $SIZE" >&2; exit 1; }

command -v adb >/dev/null || { echo "找不到 adb" >&2; exit 1; }
adb devices | tr -d '\r' | awk '$2=="device"{f=1} END{exit !f}' \
    || { echo "没有连接的 ADB 设备" >&2; exit 1; }

if [[ $STOP -eq 1 ]]; then
    echo "==> 停止 C1ancher（恢复请 adb reboot）"
    adb shell '/etc/init.d/S80app stop' >/dev/null 2>&1 || true
    sleep 1
fi

echo "==> 推送 $FRAME"
adb push "$FRAME" /tmp/c1frame.bin >/dev/null

echo "==> 写入 $EPAPER 并触发全刷"
# 必须一次 write() 写完整 5624 字节。
# 这个驱动把每次 write() 都当作一帧的开头，cat 会分多次写，
# 结果只有最后一个数据块留在屏上、从左上角开始画（尾部内容跑到顶部 + 横向折行）。
# dd 指定 bs=5624 count=1 保证只发一次 write 系统调用。
adb shell "dd if=/tmp/c1frame.bin of=$EPAPER bs=5624 count=1 2>/dev/null && echo 0 > $SYSFS/refresh"
# 同步影子帧：我们绕过了 C1ancher 直接写屏，补上这一份，
# 好让 grab-screen.sh 抓到的内容始终等于屏幕上的内容
adb shell "cat /tmp/c1frame.bin > /dev/shm/c1-screen.bin" 2>/dev/null || true

echo "==> 完成。看一眼屏幕。"
echo "    显示成负片（黑白反了）→ 改用同名的 -inv.bin"
echo "    恢复 C1ancher       → adb reboot"
