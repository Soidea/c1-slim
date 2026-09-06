#!/usr/bin/env bash
# 整机备份 —— 在改动设备之前必须先跑这个。
#
# 通过 ADB 只读地导出分区表和各个分区镜像。全程只读，不写设备任何字节。
# 这是你唯一的救砖资本：remove-original 删掉原厂软件后，设备端没有恢复路径，
# 只能靠这里备份出来的镜像。
#
# 用法：
#   macos/backup.sh                      # 备份 512MB 以下的所有分区（默认）
#   macos/backup.sh --max-mb 2048        # 放宽单分区大小上限
#   macos/backup.sh --all                # 全部分区，不限大小
#   macos/backup.sh --out ~/c1-backup    # 指定输出目录

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-adb.sh
source "$SCRIPT_DIR/lib-adb.sh"

MAX_MB=512
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-mb) MAX_MB="$2"; shift 2 ;;
        --all) MAX_MB=0; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

resolve_adb
get_only_device
assert_system_state
note "root shell 已确认，根文件系统只读。"

[[ -n "$OUT" ]] || OUT="$HOME/C1Slim-Backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
note "输出目录：$OUT"

# ---- 元信息 ---------------------------------------------------------------
note "采集设备信息..."
{
    echo "# C1-Slim backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "serial=$SERIAL"
    echo; echo "## id";        remote 'id'
    echo; echo "## uname -a";  remote 'uname -a'
    echo; echo "## /proc/partitions"; remote 'cat /proc/partitions'
    echo; echo "## /proc/mtd"; remote 'cat /proc/mtd 2>/dev/null || echo "(no mtd)"'
    echo; echo "## mount";     remote 'mount'
    echo; echo "## df -h";     remote 'df -h'
    echo; echo "## /proc/cmdline"; remote 'cat /proc/cmdline'
    echo; echo "## by-name";   remote 'ls -l /dev/block/by-name 2>/dev/null || echo "(none)"'
    echo; echo "## init.d";    remote 'ls -l /etc/init.d'
    echo; echo "## key hashes"
    remote 'sha256sum /etc/init.d/S90usb /etc/app_daemon 2>/dev/null'
} > "$OUT/device-info.txt" 2>&1
ok_lines="$(wc -l < "$OUT/device-info.txt")"
note "device-info.txt（$ok_lines 行）"

# ---- 关键小文件（快，先存）-------------------------------------------------
note "备份关键启动脚本..."
mkdir -p "$OUT/etc"
for f in /etc/init.d/S90usb /etc/app_daemon /etc/init.d/S80app; do
    if remote "test -f $f && echo yes" | grep -q yes; then
        if adb_dev pull "$f" "$OUT/etc/$(basename "$f")" >/dev/null 2>&1; then
            note "  $f"
        else
            note "  $f （拉取失败，跳过）"
        fi
    fi
done
adb_dev pull /etc/init.d "$OUT/etc/init.d" >/dev/null 2>&1 || true

# ---- 分区列表 -------------------------------------------------------------
note "枚举分区..."
PARTS="$(remote 'cat /proc/partitions' | awk 'NR>2 && $4 ~ /^mmcblk[0-9]+p[0-9]+$/ {print $4" "$3}')"
[[ -n "$PARTS" ]] || die "读不到分区表，检查 /proc/partitions"

echo
printf '  %-14s %10s   %s\n' "分区" "大小" "动作"
printf '  %-14s %10s   %s\n' "------------" "---------" "------"
TODO=()
while read -r name blocks; do
    [[ -n "$name" ]] || continue
    mb=$(( blocks / 1024 ))
    if [[ "$MAX_MB" -eq 0 || "$mb" -le "$MAX_MB" ]]; then
        printf '  %-14s %7s MB   备份\n' "$name" "$mb"
        TODO+=("$name")
    else
        printf '  %-14s %7s MB   跳过（超过 %s MB）\n' "$name" "$mb" "$MAX_MB"
    fi
done <<< "$PARTS"
echo

[[ ${#TODO[@]} -gt 0 ]] || die "没有可备份的分区，试试 --max-mb 更大的值或 --all"

TOTAL_MB=0
while read -r name blocks; do
    for t in "${TODO[@]}"; do
        [[ "$t" == "$name" ]] && TOTAL_MB=$(( TOTAL_MB + blocks/1024 ))
    done
done <<< "$PARTS"
note "将导出 ${#TODO[@]} 个分区，合计约 ${TOTAL_MB} MB。USB 2.0 大约每分钟 60-100 MB。"
echo

mkdir -p "$OUT/partitions"
for name in "${TODO[@]}"; do
    dest="$OUT/partitions/$name.img"
    printf '  导出 %-12s ' "$name"
    # exec-out 是二进制安全的，不会做 CRLF 转换
    if adb_dev exec-out "dd if=/dev/block/$name bs=1M 2>/dev/null" > "$dest"; then
        size=$(stat -f%z "$dest" 2>/dev/null || stat -c%s "$dest")
        if [[ "$size" -gt 0 ]]; then
            printf '%s MB\n' "$(( size / 1048576 ))"
        else
            printf '空 —— 删除\n'; rm -f "$dest"
        fi
    else
        printf '失败\n'; rm -f "$dest"
    fi
done

# ---- 校验和 ---------------------------------------------------------------
note "生成 SHA256SUMS..."
( cd "$OUT" && find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} \; | sort -k2 > SHA256SUMS )

echo
echo "备份完成：$OUT"
du -sh "$OUT" 2>/dev/null | awk '{print "  总大小 " $1}'
echo "  $(grep -c . "$OUT/SHA256SUMS") 个文件已记录校验和"
echo
echo "把这个目录复制到另一块盘或云盘再继续刷机。"
echo "校验：cd '$OUT' && shasum -a 256 -c SHA256SUMS"
