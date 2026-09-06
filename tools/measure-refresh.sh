#!/usr/bin/env bash
# 测量 C1-Slim 电子纸的刷新耗时。
#
# 显存读不回来（驱动只写），但 sysfs 的 refresh_cnt 可读，
# 所以刷新次数和耗时可以精确测，不用靠眼睛估。
#
#   ./measure-refresh.sh          # 全刷 + 快刷各测一轮
#   ./measure-refresh.sh -n 10    # 每轮 10 次（默认 5）
#
# 测量在设备端完成，不含 adb 往返延迟。
# 每次交替推送两张内容不同的帧，确保刷新真的有活干。

set -euo pipefail
SYSFS=/sys/devices/platform/e0266a128/epaper
N=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) N="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

command -v adb >/dev/null || { echo "找不到 adb" >&2; exit 1; }
adb devices | tr -d '\r' | awk '$2=="device"{f=1} END{exit !f}' \
    || { echo "没有连接的 ADB 设备" >&2; exit 1; }

for f in card-01-low.bin card-03-high.bin; do
    [[ -f "$f" ]] || { echo "缺少 $f，先跑 python3 approval.py" >&2; exit 1; }
done

echo "==> 停止 C1ancher，独占屏幕（恢复请 adb reboot）"
adb shell '/etc/init.d/S80app stop' >/dev/null 2>&1 || true
sleep 1

echo "==> 上传两张测试帧"
adb push card-01-low.bin  /tmp/fa.bin >/dev/null
adb push card-03-high.bin /tmp/fb.bin >/dev/null

echo "==> 当前状态"
adb shell "echo '    refresh_cnt   ' \$(cat $SYSFS/refresh_cnt 2>/dev/null)
           echo '    refresh_max   ' \$(cat $SYSFS/refresh_max 2>/dev/null)
           echo '    fast_only     ' \$(cat $SYSFS/fast_refresh_only 2>/dev/null)" | tr -d '\r'

run_round () {
    local mode="$1" fast="$2"
    echo
    echo "=== $mode  （fast_refresh_only=$fast，$N 次）==="
    adb shell "
        S=$SYSFS
        echo $fast > \$S/fast_refresh_only 2>/dev/null || echo '    (无法设置 fast_refresh_only)'
        C0=\$(cat \$S/refresh_cnt 2>/dev/null || echo 0)
        T0=\$(cat /proc/uptime | cut -d' ' -f1)
        i=0
        while [ \$i -lt $N ]; do
            if [ \$((i % 2)) -eq 0 ]; then dd if=/tmp/fa.bin of=/dev/epaper_lcd bs=5624 count=1 2>/dev/null
            else dd if=/tmp/fb.bin of=/dev/epaper_lcd bs=5624 count=1 2>/dev/null; fi
            echo 0 > \$S/refresh
            i=\$((i+1))
        done
        T1=\$(cat /proc/uptime | cut -d' ' -f1)
        C1=\$(cat \$S/refresh_cnt 2>/dev/null || echo 0)
        awk -v t0=\$T0 -v t1=\$T1 -v n=$N -v c0=\$C0 -v c1=\$C1 'BEGIN{
            d=t1-t0
            printf \"    总耗时      %.2f s\n\", d
            printf \"    每次        %.0f ms\n\", d*1000/n
            printf \"    refresh_cnt %s -> %s  (+%s)\n\", c0, c1, c1-c0
        }'
    " | tr -d '\r'
}

run_round "全刷 FULL" 0
run_round "快刷 FAST" 1

echo
echo "==> 恢复 fast_refresh_only 默认值并重启"
adb shell "echo 0 > $SYSFS/fast_refresh_only" >/dev/null 2>&1 || true
echo "    跑 adb reboot 让设备回到 C1ancher"
