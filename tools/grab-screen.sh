#!/usr/bin/env bash
# 从 C1-Slim 截图。
#
#   ./grab-screen.sh                 # 抓一张，存到 shots/ 并打开
#   ./grab-screen.sh -o before.png   # 指定输出名
#   ./grab-screen.sh --invert        # 位极性相反时
#   ./grab-screen.sh --watch         # 每 2 秒抓一次
#
# 原理：面板驱动只写不可读，屏幕内容无法回读。打了影子帧补丁的 C1ancher
# 会在每次写屏时把同一份数据另存到 /dev/shm/c1-screen.bin，这里 pull 回来。
#
# 注意：本机 adbd 版本较老，不支持 exec-out，所以用 adb pull。

set -euo pipefail
SHADOW=/dev/shm/c1-screen.bin
BYTES=5624
INVERT=""
OUT=""
WATCH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --invert) INVERT="--invert"; shift ;;
        --watch)  WATCH=1; shift ;;
        -o)       OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

command -v adb >/dev/null || { echo "找不到 adb" >&2; exit 1; }
adb devices | tr -d '\r' | awk '$2=="device"{f=1} END{exit !f}' \
    || { echo "没有连接的 ADB 设备" >&2; exit 1; }

file_size () {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

hint_not_installed () {
    # 引号包住的 heredoc：不做变量展开，避免全角标点粘进变量名
    cat >&2 <<'MSG'

多半是设备上跑的还是没打影子帧补丁的 C1ancher。

先确认设备上的哈希：
    adb shell 'sha256sum /usr/data/c1/bin/C1ancher'
    期望 39ad41e0c86b93ef99e423df88ea4706120da1ad74da4bf4be12358800044178

不对就重新安装：
    ~/Downloads/c1-approval/setup.sh
MSG
}

grab_once () {
    local out="$1"
    local bin="${out%.png}.bin"
    local size

    rm -f "$bin"
    # 老 adbd 不支持 exec-out，用 pull
    if ! adb pull "$SHADOW" "$bin" >/dev/null 2>&1; then
        echo "adb pull 失败，设备上可能还没有 $SHADOW" >&2
        hint_not_installed
        return 1
    fi

    size=$(file_size "$bin")
    if [[ "$size" -ne "$BYTES" ]]; then
        printf '影子帧大小不对：拿到 %s 字节，应为 %s\n' "$size" "$BYTES" >&2
        rm -f "$bin"
        hint_not_installed
        return 1
    fi

    python3 c1gfx.py $INVERT unpack "$bin" "$out" --scale 4 >/dev/null
    printf '==> %s   %s 字节\n' "$out" "$size"
}

mkdir -p shots

if [[ $WATCH -eq 1 ]]; then
    echo "每 2 秒抓一张到 shots/watch.png，Ctrl-C 停止。"
    while true; do
        grab_once "shots/watch.png" || exit 1
        sleep 2
    done
fi

[[ -n "$OUT" ]] || OUT="shots/shot-$(date +%Y%m%d-%H%M%S).png"
grab_once "$OUT"
command -v open >/dev/null && open "$OUT" || true
