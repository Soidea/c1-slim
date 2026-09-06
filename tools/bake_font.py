#!/usr/bin/env python3
"""从 Ark Pixel Font 的字形 PNG 源文件烘焙出紧凑的位图数据模块。

Ark Pixel Font (方舟像素字体) — Copyright (c) 2021, TakWolf
https://github.com/TakWolf/ark-pixel-font  ·  SIL Open Font License 1.1

字形源是逐字的 PNG 位图，alpha 通道即落墨。直接读像素，
完全绕开 TrueType 栅格化 —— 不存在抗锯齿后阈值化导致笔画不匀的问题。
"""
from PIL import Image
from pathlib import Path

SRC = Path("/tmp/ark-src/assets/glyphs")
SIZES = (10, 12, 16)
CHARS = [chr(c) for c in range(0x20, 0x7F)] + ['←', '↑', '→', '↓']


def glyph_path(size, cp):
    """monospaced 优先，回退到 common（箭头等符号只在 common 里）。"""
    for variant in ("monospaced", "common"):
        hits = list((SRC / str(size) / variant).glob(f"**/{cp:04X}.png"))
        if hits:
            return hits[0]
    return None


def extract(size, char):
    path = glyph_path(size, ord(char))
    if path is None:
        return None
    im = Image.open(path).convert("RGBA")
    px = im.load()
    rows = []
    for y in range(im.height):
        bits = 0
        for x in range(im.width):
            if px[x, y][3] > 127:
                bits |= 1 << (im.width - 1 - x)
        rows.append(bits)
    return im.width, im.height, rows


def main():
    out = ['"""',
           '点阵字库数据 —— 由 Ark Pixel Font 的字形源烘焙而来。',
           '',
           'Ark Pixel Font (方舟像素字体)',
           'Copyright (c) 2021, TakWolf  ·  https://github.com/TakWolf/ark-pixel-font',
           'SIL Open Font License 1.1 —— 见同目录 LICENSE-OFL。',
           '',
           '本文件由 bake_font.py 自动生成，请勿手改。',
           '每个字形存为 (宽度, [每行位掩码])，最高位对应最左像素。\n全角字形（如箭头）宽度是等宽格的两倍。',
           '"""',
           '']
    meta = {}
    for size in SIZES:
        data, w, h = {}, None, None
        missing = []
        for ch in CHARS:
            got = extract(size, ch)
            if got is None:
                missing.append(hex(ord(ch))); continue
            gw, gh, rows = got
            if ch.isascii():                      # ASCII 定义等宽格
                w = w or gw; h = h or gh
            data[ch] = (gw, rows)                 # 保留各自真实宽度（箭头是全角，占两格）
        meta[size] = (w, h, len(data))
        out.append(f"# ---- {size}px  等宽格 {w}x{h}  {len(data)} 个字形 ----")
        out.append(f"W{size}, H{size} = {w}, {h}")
        out.append(f"F{size} = {{")
        for ch, (gw, rows) in data.items():
            out.append(f"    {ch!r}: ({gw}, {rows}),")
        out.append("}")
        out.append("")
        if missing:
            print(f"  {size}px 缺失: {missing}")
    out.append("FONTS = {" + ", ".join(f"{s}: (W{s}, H{s}, F{s})" for s in SIZES) + "}")
    Path("arkpix_data.py").write_text("\n".join(out), encoding="utf-8")
    for s, (w, h, n) in meta.items():
        print(f"{s}px  单元 {w}x{h}  {n} 字形  →  296/{w} = {296//w} 列, 152/{h} = {152//h} 行")
    print("arkpix_data.py", Path("arkpix_data.py").stat().st_size, "字节")


if __name__ == "__main__":
    main()
