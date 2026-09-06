#!/usr/bin/env bash
# 环境自检 —— 刷机前先跑这个。
# 逐项检查 macOS 侧的准备情况，并列出热点上的客户端（帮你找到设备 MAC）。
# 只读，不改任何东西。

set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
hint() { printf '      → %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "1. 系统"
if [[ "$(uname -s)" == "Darwin" ]]; then
    ok "macOS $(sw_vers -productVersion) ($(uname -m))"
else
    bad "不是 macOS（当前 $(uname -s)）"; hint "本套脚本只支持 macOS"
fi

head_ "2. 命令行工具"
if command -v adb >/dev/null 2>&1; then
    ok "adb — $(adb version 2>/dev/null | head -1)"
else
    bad "adb 未安装"; hint "brew install --cask android-platform-tools"
fi
if command -v python3 >/dev/null 2>&1; then
    ok "python3 — $(python3 --version 2>&1)"
else
    bad "python3 未安装"; hint "brew install python3"
fi
if python3 -c "import cryptography" 2>/dev/null; then
    ok "python cryptography — $(python3 -c 'import cryptography;print(cryptography.__version__)' 2>/dev/null)"
else
    bad "python 缺少 cryptography"; hint "pip3 install cryptography"
fi
command -v ssh-keygen >/dev/null 2>&1 && ok "ssh-keygen" || bad "ssh-keygen 缺失"

head_ "3. 互联网共享 / 热点"
BRIDGE=""; GW=""
while read -r name; do
    body="$(ifconfig "$name" 2>/dev/null)"
    addr="$(grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$body" | head -1 | awk '{print $2}')"
    [[ -n "$addr" ]] && { BRIDGE="$name"; GW="$addr"; break; }
done < <(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^bridge')

if [[ -n "$BRIDGE" ]]; then
    ok "$BRIDGE 已启用，网关 $GW"
else
    bad "没有找到已启用的共享网桥"
    hint "系统设置 → 通用 → 共享 → 互联网共享，共享给 Wi-Fi"
    hint "M 系 Mac 建议：上网走 USB-C 转以太网，共享给 Wi-Fi（单网卡自共享常不稳）"
fi

head_ "4. 热点上的客户端（在这里找你的设备 MAC）"
FOUND=0
if [[ -n "$BRIDGE" ]]; then
    printf '      %-18s %-20s %s\n' "IP" "MAC" "来源"
    while IFS='|' read -r ip mac src; do
        printf '      %-18s %-20s %s\n' "$ip" "$mac" "$src"; FOUND=$((FOUND+1))
    done < <(
        { arp -an -i "$BRIDGE" 2>/dev/null \
            | sed -nE 's/.*\(([0-9.]+)\) at ([0-9a-fA-F:]+).*/\1|\2|arp/p'
          python3 - <<'PY' 2>/dev/null
import re,pathlib
p=pathlib.Path("/var/db/dhcpd_leases")
if p.exists():
    ip=mac=name=None
    for line in p.read_text(errors="replace").splitlines():
        s=line.strip()
        if s=="{": ip=mac=name=None
        elif s=="}":
            if ip and mac: print(f"{ip}|{mac}|dhcp {name or ''}".rstrip())
        elif s.startswith("ip_address="): ip=s.split("=",1)[1]
        elif s.startswith("name="): name=s.split("=",1)[1]
        elif s.startswith("hw_address="): mac=s.split("=",1)[1].split(",")[-1]
PY
        } | sort -u -t'|' -k1,1
    )
    if [[ $FOUND -eq 0 ]]; then
        warn "网桥上没有客户端"
        hint "把 C1-Slim 连上这个 Mac 热点，然后重跑本脚本"
        hint "设备连上后这里会出现它的 IP 和 MAC，记下 MAC 传给下一步"
    else
        ok "发现 $FOUND 个客户端（上面列出）"
        hint "认不出哪个是 C1-Slim？把设备 Wi-Fi 关掉再跑一次，消失的那行就是它"
    fi
else
    warn "网桥未就绪，跳过客户端扫描"
fi

head_ "5. pf 包过滤"
if sudo -n true 2>/dev/null; then
    if sudo -n pfctl -s info 2>/dev/null | head -1 | grep -q Enabled; then
        ok "pf 已启用"
    else
        warn "pf 未启用（放行脚本会自动 pfctl -E 打开）"
    fi
    if grep -q 'rdr-anchor "com.apple/\*"' /etc/pf.conf 2>/dev/null; then
        ok "/etc/pf.conf 含 rdr-anchor \"com.apple/*\"（重定向所需）"
    else
        bad "/etc/pf.conf 缺少 rdr-anchor \"com.apple/*\""
        hint "macOS 默认自带这一行，若缺失说明被改过"
    fi
    LEFT="$(sudo -n pfctl -a com.apple/c1slim-adb -s nat 2>/dev/null | grep -c rdr || true)"
    [[ "${LEFT:-0}" -eq 0 ]] && ok "无残留 rdr 规则" \
        || { warn "有 $LEFT 条残留 rdr 规则"; hint "sudo pfctl -a com.apple/c1slim-adb -F all"; }
else
    warn "未取得 sudo（跳过 pf 检查）"; hint "想连 pf 一起检查：sudo ./doctor.sh"
fi

head_ "6. ADB 设备"
if command -v adb >/dev/null 2>&1; then
    LINES="$(adb devices 2>/dev/null | tr -d '\r' | awk '$2=="device"{print $1}')"
    N="$(printf '%s\n' "$LINES" | grep -c . || true)"
    if [[ "$N" -eq 1 ]]; then
        ok "ADB 已连接：$LINES"
        ID="$(adb shell id 2>/dev/null | tr -d '\r')"
        grep -q 'uid=0(root)' <<<"$ID" && ok "root shell：$ID" || bad "非 root：$ID"
        RM="$(adb shell mount 2>/dev/null | tr -d '\r' | grep -E ' on / type ' | head -1)"
        grep -qE '\(ro(,|\))' <<<"$RM" && ok "根文件系统只读（正常）" || warn "根文件系统非只读：$RM"
        S90="$(adb shell sha256sum /etc/init.d/S90usb 2>/dev/null | tr -d '\r' | awk '{print $1}')"
        case "$S90" in
          c2b278b283e9bf851461d9e8f6edfd207cec3b120585f0e091777d163562e965)
            ok "S90usb = 原厂（ADB 尚未持久化）" ;;
          626e4c5d600b543531337eb67220b0a7520d461211cc7ecafd36666d4f8905cb)
            ok "S90usb = 已开启常驻 ADB" ;;
          "") warn "读不到 S90usb 哈希" ;;
          *)  warn "S90usb 哈希未知：$S90" ;;
        esac
    elif [[ "$N" -eq 0 ]]; then
        warn "当前无 ADB 设备（首次刷机时正常）"
        hint "先跑 c1-adb-admit-macos.py 临时打开 ADB"
    else
        bad "接了 $N 台 ADB 设备，安装脚本要求恰好 1 台"
    fi
fi

printf '\n\033[1m结果：\033[0m %d 通过 / %d 警告 / %d 失败\n' "$PASS" "$WARN" "$FAIL"
[[ $FAIL -eq 0 ]] && echo "可以继续下一步。" || echo "先修掉上面的 ✗ 再继续。"
exit 0
