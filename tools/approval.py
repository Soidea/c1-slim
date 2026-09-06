#!/usr/bin/env python3
"""
C1-Slim 审批卡片 —— 296x152 / 1bpp 真机帧生成器。

排版系统（只有三条规则，全部来自这块屏本身）：

  1. 一套字体：Ark Pixel Font（方舟像素字体，OFL-1.1）。字形源本身就是逐字
     PNG 位图，直接读像素，完全绕开 TrueType 栅格化 —— 不存在抗锯齿后阈值化
     导致笔画时粗时细的问题。

  2. 只用它的原生字号，不缩放。16px（8x16 格）给主命令，12px（6x12 格）给
     其余一切。缩放像素字体会破坏笔画均匀性，正是要避开的问题。

  3. 分区起点全部是 8 的倍数。16px 格高正好是两个字节行，行起点落在字节
     边界上，blit 退化成纯字节拷贝。

风险等级靠"形"编码，不只靠字：1-bit 没有颜色可用。
  LOW  = 计量条 1/3，25% 抖动
  MED  = 2/3，50% 抖动
  HIGH = 3/3 实心 + 顶栏整条反色（余光一瞥就能认出，不用读字）
"""
import importlib.util, sys
from PIL import Image, ImageDraw

spec = importlib.util.spec_from_file_location("g", "c1gfx.py")
g = importlib.util.module_from_spec(spec); sys.modules["g"] = g; spec.loader.exec_module(g)
import arkpix as P

W, H = g.WIDTH, g.HEIGHT                   # 296 x 152
M = 4                                      # 左右留白
BIG, SMALL = 16, 12                        # 主命令 / 其余一切
ROW = 8                                    # 字节行

# 分区边界，全部是 8 的倍数
HEAD_B  = 16      # 顶栏底边   （行 0-1）
RISK_T  = 112     # 风险条顶边 （行 14-15）
KEYS_T  = 128     # 按键区顶边 （行 16-18）

TEXT_Y_IN_16 = 2  # 12px 高的字在 16px 带里垂直居中


def canvas():
    im = Image.new("1", (W, H), 1)          # 1 = 白纸
    return im, ImageDraw.Draw(im)


def dither(d, box, level, fill=0):
    """Bayer 4x4 有序抖动。空间固定 —— 内容小改只翻转真正变化的像素，
    不像误差扩散那样整片重随机化，电子纸才不会大面积残影。"""
    m = g.BAYER4; n = len(m); denom = n * n
    x0, y0, x1, y1 = box
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            if (m[y % n][x % n] + 0.5) / denom < level:
                d.point((x, y), fill=fill)


def rule(d, y):
    d.line([(0, y), (W - 1, y)], fill=0)


RISK = {                       # 段数, 抖动浓度, 顶栏是否反色
    "LOW":  (1, 0.25, False),
    "MED":  (2, 0.50, False),
    "HIGH": (3, 1.00, True),
}


def header(d, left, right, invert):
    if invert:
        d.rectangle([0, 0, W - 1, HEAD_B - 1], fill=0)
        fg = 1
    else:
        rule(d, HEAD_B - 1)
        fg = 0
    P.draw_text(d, (M, TEXT_Y_IN_16), left.upper(), SMALL, fill=fg)
    P.draw_text(d, (W - M - P.text_width(right, SMALL), TEXT_Y_IN_16), right, SMALL, fill=fg)


def risk_row(d, level):
    segments, density, _ = RISK[level]
    rule(d, RISK_T - 1)
    y = RISK_T + TEXT_Y_IN_16
    P.draw_text(d, (M, y), "RISK", SMALL)

    # 三段计量条，落在网格上：每段 60px，间隔 4px
    bx = 40
    for i in range(3):
        x0 = bx + i * 64
        x1 = x0 + 59
        d.rectangle([x0, RISK_T + 4, x1, RISK_T + 11], outline=0)
        if i < segments:
            dither(d, (x0 + 2, RISK_T + 6, x1 - 2, RISK_T + 9), density)

    P.draw_text(d, (W - M - P.text_width(level, SMALL), y), level, SMALL)


def keys_row(d, labels):
    rule(d, KEYS_T - 1)
    y = KEYS_T + 6                          # 24px 带里垂直居中
    for x, label in zip((M, 104, 200), labels):
        P.draw_text(d, (x, y), label, SMALL)


def card(agent, elapsed, command, context, level,
         keys=("OK ALLOW", "BACK DENY", P.ARROW_RIGHT + " DETAIL")):
    im, d = canvas()
    _, _, invert = RISK[level]
    header(d, agent, elapsed, invert)

    # 主命令 2x（12x16），最多两行；放不下就在 1x 上换行
    body_w = W - 2 * M
    lines, scale = P.wrap(command, body_w, BIG), BIG
    if len(lines) > 2:
        lines, scale = P.wrap(command, body_w, SMALL)[:3], SMALL

    lh = P.text_height(scale)
    block = len(lines) * lh + (4 + ROW if context else 0)
    y = HEAD_B + ((RISK_T - HEAD_B - block) // ROW // 2) * ROW    # 居中并吸附到 8px 行
    for line in lines:
        P.draw_text(d, (M, y), line, scale)
        y += lh
    if context:
        P.draw_text(d, (M, y + 4), P.fit(context, body_w, SMALL), SMALL)

    risk_row(d, level)
    keys_row(d, keys)
    return im


def idle(agent, headline, detail, keys):
    im, d = canvas()
    header(d, agent, "IDLE", False)
    P.draw_text(d, (M, 32), headline, BIG, scale=2)   # 整数倍放大，锐度不变
    P.draw_text(d, (M, 80), P.fit(detail, W - 2 * M, SMALL), SMALL)
    dither(d, (M, 96, W - M - 1, 99), 0.5)
    rule(d, KEYS_T - 1)
    y = KEYS_T + 6
    for x, label in zip((M, 104, 200), keys):
        P.draw_text(d, (x, y), label, SMALL)
    return im


CARDS = [
    ("01-low", lambda: card("claude code", "0m 08s",
        "npm test", "~/work/ket-agent", "LOW")),
    ("02-med", lambda: card("claude code", "1m 32s",
        "npm install dify-client", "adds 1 dependency to package.json", "MED")),
    ("03-high", lambda: card("claude code", "2m 14s",
        "rm -rf node_modules/", "~/work/ket-agent - not reversible", "HIGH")),
    ("04-high", lambda: card("codex", "4m 01s",
        "git push --force origin main", "remote loses 3 commits", "HIGH")),
    ("05-idle", lambda: idle("claude code", "WAITING",
        "last 14:32 - 7 approved - 1 denied",
        ("OK WAKE", P.ARROW_RIGHT + " SESSION", P.ARROW_DOWN + " LOG"))),
]


if __name__ == "__main__":
    made = []
    for name, fn in CARDS:
        im = fn()
        px = im.load()
        bits = [[0 if px[x, y] else 1 for x in range(W)] for y in range(H)]
        frame = g.pack(bits, False)
        assert len(frame) == g.FRAME_BYTES
        assert g.unpack(frame, False) == bits, "往返不一致"
        open(f"card-{name}.bin", "wb").write(frame)
        im.convert("RGB").resize((W * 4, H * 4), Image.NEAREST).save(f"card-{name}.png")
        ink = sum(sum(r) for r in bits) / (W * H)
        made.append((name, im))
        print(f"card-{name}.bin  5624 B  ink {ink*100:.1f}%")

    S, PAD, LAB = 3, 20, 18
    cols = 2; rows = (len(made) + cols - 1) // cols
    tw, th = W * S, H * S
    sheet = Image.new("RGB", (cols * (tw + PAD) + PAD, rows * (th + LAB + PAD) + PAD),
                      (231, 233, 227))
    sd = ImageDraw.Draw(sheet)
    for i, (name, im) in enumerate(made):
        cx = PAD + (i % cols) * (tw + PAD)
        cy = PAD + (i // cols) * (th + LAB + PAD)
        lw = P.text_width(name, SMALL)
        lab = Image.new("1", (lw, 12), 1)
        P.draw_text(ImageDraw.Draw(lab), (0, 0), name, SMALL)
        sheet.paste(lab.convert("RGB").resize((lw, 12), Image.NEAREST), (cx, cy + 4))
        sheet.paste(im.convert("RGB").resize((tw, th), Image.NEAREST), (cx, cy + LAB))
        sd.rectangle([cx - 1, cy + LAB - 1, cx + tw, cy + LAB + th], outline=(120, 118, 112))
    sheet.save("approval-cards.png")
    print("approval-cards.png")
