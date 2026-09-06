"""
点阵文字渲染 —— 基于 Ark Pixel Font（方舟像素字体）。

Ark Pixel Font · Copyright (c) 2021, TakWolf · SIL Open Font License 1.1
https://github.com/TakWolf/ark-pixel-font

三档等宽字号，都是像素级设计，按原始尺寸使用，不缩放：
    10px → 5x10 单元 → 59 列 x 15 行
    12px → 6x12 单元 → 49 列 x 12 行
    16px → 8x16 单元 → 37 列 x  9 行   （16 是 8 的倍数，行起点落在字节边界）
"""
from arkpix_data import FONTS

SIZES = sorted(FONTS)


def cell(size):
    w, h, _ = FONTS[size]
    return w, h


def text_width(text, size, scale=1):
    """逐字累加真实宽度 —— 全角字形（箭头）占两个等宽格。"""
    _, _, glyphs = FONTS[size]
    cw = FONTS[size][0]
    return sum(glyphs[c][0] if c in glyphs else cw for c in text) * scale


def text_height(size, scale=1):
    _, h, _ = FONTS[size]
    return h * scale


def draw_text(draw, xy, text, size, fill=0, scale=1):
    """在 PIL ImageDraw 上按原始像素画字。返回下一个字符的 x。

    scale 只接受正整数。整数倍放大是像素字体唯一合法的缩放方式：
    每个原始像素变成 scale x scale 的实心方块，笔画粗细依然完全均匀。
    非整数倍会引入半像素，笔画就不匀了。"""
    if scale < 1 or int(scale) != scale:
        raise ValueError("scale 必须是 >=1 的整数")
    scale = int(scale)
    _, _, glyphs = FONTS[size]
    cw = FONTS[size][0]
    x, y0 = xy
    for ch in text:
        entry = glyphs.get(ch)
        if entry is None:
            x += cw * scale
            continue
        gw, rows = entry
        for ry, bits in enumerate(rows):
            if not bits:
                continue
            for rx in range(gw):
                if bits >> (gw - 1 - rx) & 1:
                    px, py = x + rx * scale, y0 + ry * scale
                    if scale == 1:
                        draw.point((px, py), fill=fill)
                    else:
                        draw.rectangle([px, py, px + scale - 1, py + scale - 1], fill=fill)
        x += gw * scale
    return x


def cols(size, px):
    w, _, _ = FONTS[size]
    return px // w


def fit(text, max_px, size):
    n = cols(size, max_px)
    return text if len(text) <= n else text[:max(0, n - 2)] + ".."


def wrap(text, max_px, size):
    n = cols(size, max_px)
    lines, cur = [], ""
    for word in text.split(" "):
        trial = (cur + " " + word).strip()
        if len(trial) <= n:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = word if len(word) <= n else word[:n]
    if cur:
        lines.append(cur)
    return lines


ARROW_LEFT, ARROW_UP, ARROW_RIGHT, ARROW_DOWN = '←', '↑', '→', '↓'


if __name__ == "__main__":
    from PIL import Image, ImageDraw
    samples = ["npm install dify-client@2.4", "git push --force origin main",
               "package.json google gpqjy", "0O1lI  g9 gs pr  ←↑→↓"]
    pad, gap = 4, 6
    rows = [(s, sz) for sz in SIZES for s in samples]
    width = max(text_width(s, sz) for s, sz in rows) + pad * 2
    height = sum(text_height(sz) + gap for _, sz in rows) + pad * 2
    im = Image.new("1", (width, height), 1)
    d = ImageDraw.Draw(im)
    y = pad
    for s, sz in rows:
        draw_text(d, (pad, y), s, sz)
        y += text_height(sz) + gap
    im.convert("RGB").resize((width * 3, height * 3), Image.NEAREST).save("arkpix-sample.png")
    print("arkpix-sample.png", im.size)
