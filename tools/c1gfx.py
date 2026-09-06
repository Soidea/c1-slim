#!/usr/bin/env python3
"""
c1gfx - C1-Slim e-paper framebuffer round-trip tool.

Panel: SEEKINK E0266A128, 296x152, 1bpp, ~125 DPI.

Packing: strip-major (banded). 屏幕分成 19 条 8px 高的横带；每条带内是 296 个
连续字节，每列一个；一个字节装该带内垂直相邻的 8 个像素，最高位对应较小的 Y。

    byte = buf[(y >> 3) * 296 + x]
    bit  = 7 - (y & 7)
    1 = 黑

依据 C1ancher 源码 src/display/frame.c 的 c1_display_frame_set_pixel()：
    offset = (y / 8) * C1_DISPLAY_WIDTH + x
    mask   = 0x80 >> (y % 8)
并已用真机截图反推验证。

注意：按列打包（296 列 x 19 字节）和按带打包（19 带 x 296 字节）总字节数
都是 5624，尺寸校验分辨不出来 —— 早期版本用错了列优先，自洽的往返测试
全部通过，但推到设备上是竖条纹乱码。

pack    image -> .bin ready for `adb push` + `cat > /dev/epaper_lcd`
unpack  .bin  -> PNG preview (optionally scaled, with the 8px byte-row grid)
ramp    generate a dither test card

Bit polarity is NOT documented for this panel. Default here is 1 = black.
If the device shows an inverted image, add --invert (both ways) and note it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ModuleNotFoundError:
    raise SystemExit("Missing dependency. Run: pip3 install pillow")

WIDTH, HEIGHT = 296, 152
STRIPS = HEIGHT // 8             # 19 条横带，无余数
FRAME_BYTES = WIDTH * STRIPS     # 5624

# Bayer ordered-dither matrices, normalised to 0..1 thresholds.
# Ordered dither is spatially fixed, so a small content change flips only the
# pixels that actually changed. Error diffusion re-randomises whole regions and
# makes e-paper ghost badly, which is why it is not the default here.
BAYER2 = [[0, 2], [3, 1]]
BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
BAYER8 = [
    [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
]
MATRICES = {"bayer2": BAYER2, "bayer4": BAYER4, "bayer8": BAYER8}


def to_luma(image: Image.Image, fit: str) -> Image.Image:
    """Return a WIDTH x HEIGHT 8-bit greyscale image."""
    grey = image.convert("L")
    if grey.size == (WIDTH, HEIGHT):
        return grey
    if fit == "stretch":
        return grey.resize((WIDTH, HEIGHT), Image.LANCZOS)
    if fit == "pad":
        grey.thumbnail((WIDTH, HEIGHT), Image.LANCZOS)
        canvas = Image.new("L", (WIDTH, HEIGHT), 255)
        canvas.paste(grey, ((WIDTH - grey.width) // 2, (HEIGHT - grey.height) // 2))
        return canvas
    # cover: scale to fill, centre-crop
    scale = max(WIDTH / grey.width, HEIGHT / grey.height)
    resized = grey.resize(
        (max(1, round(grey.width * scale)), max(1, round(grey.height * scale))),
        Image.LANCZOS,
    )
    left = (resized.width - WIDTH) // 2
    top = (resized.height - HEIGHT) // 2
    return resized.crop((left, top, left + WIDTH, top + HEIGHT))


def halftone(grey: Image.Image, mode: str, level: int) -> list[list[int]]:
    """Return a HEIGHT x WIDTH matrix of 1 = ink (black), 0 = paper."""
    pixels = grey.load()

    if mode == "threshold":
        return [[1 if pixels[x, y] < level else 0 for x in range(WIDTH)]
                for y in range(HEIGHT)]

    if mode in MATRICES:
        matrix = MATRICES[mode]
        size = len(matrix)
        denominator = size * size
        out = []
        for y in range(HEIGHT):
            row = []
            for x in range(WIDTH):
                # +0.5 centres the threshold inside its quantisation bucket
                limit = (matrix[y % size][x % size] + 0.5) / denominator * 255
                row.append(1 if pixels[x, y] < limit else 0)
            out.append(row)
        return out

    # Error diffusion. Included for photographs, not for UI chrome.
    kernels = {
        "floyd": ([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16),
        "atkinson": ([(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1),
                      (1, 1, 1), (0, 2, 1)], 8),
    }
    if mode not in kernels:
        raise SystemExit(f"unknown dither mode: {mode}")
    kernel, divisor = kernels[mode]
    buffer = [[float(pixels[x, y]) for x in range(WIDTH)] for y in range(HEIGHT)]
    out = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        for x in range(WIDTH):
            old = buffer[y][x]
            new = 255.0 if old >= 128 else 0.0
            out[y][x] = 0 if new else 1
            error = old - new
            for dx, dy, weight in kernel:
                nx, ny = x + dx, y + dy
                if 0 <= nx < WIDTH and 0 <= ny < HEIGHT:
                    buffer[ny][nx] += error * weight / divisor
    return out


def pack(bits: list[list[int]], invert: bool) -> bytes:
    """Strip-major: 19 条 8px 横带，每带 296 字节，MSB = 较小的 Y。"""
    frame = bytearray(FRAME_BYTES)
    for y in range(HEIGHT):
        base = (y >> 3) * WIDTH
        mask = 1 << (7 - (y & 7))
        row = bits[y]
        for x in range(WIDTH):
            value = row[x]
            if invert:
                value ^= 1
            if value:
                frame[base + x] |= mask
    return bytes(frame)


def unpack(frame: bytes, invert: bool) -> list[list[int]]:
    if len(frame) != FRAME_BYTES:
        raise SystemExit(
            f"frame is {len(frame)} bytes, expected {FRAME_BYTES}"
        )
    bits = [[0] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        base = (y >> 3) * WIDTH
        shift = 7 - (y & 7)
        row = bits[y]
        for x in range(WIDTH):
            value = (frame[base + x] >> shift) & 1
            row[x] = value ^ 1 if invert else value
    return bits


def render(bits: list[list[int]], scale: int, grid: bool) -> Image.Image:
    image = Image.new("RGB", (WIDTH, HEIGHT), (255, 255, 255))
    pixels = image.load()
    for y in range(HEIGHT):
        row = bits[y]
        for x in range(WIDTH):
            if row[x]:
                pixels[x, y] = (0, 0, 0)
    if scale > 1:
        image = image.resize((WIDTH * scale, HEIGHT * scale), Image.NEAREST)
    if grid and scale > 1:
        draw = ImageDraw.Draw(image, "RGBA")
        for row_index in range(1, STRIPS):
            y = row_index * 8 * scale
            draw.line([(0, y), (image.width, y)], fill=(255, 0, 0, 90), width=1)
    return image


def cmd_pack(args: argparse.Namespace) -> None:
    grey = to_luma(Image.open(args.input), args.fit)
    bits = halftone(grey, args.dither, args.level)
    frame = pack(bits, args.invert)
    Path(args.output).write_bytes(frame)
    ink = sum(sum(row) for row in bits)
    print(f"wrote {args.output}  {len(frame)} bytes")
    print(f"ink coverage {ink / (WIDTH * HEIGHT) * 100:.1f}%  dither={args.dither}")
    if args.preview:
        render(bits, args.scale, args.grid).save(args.preview)
        print(f"preview {args.preview}")


def cmd_unpack(args: argparse.Namespace) -> None:
    bits = unpack(Path(args.input).read_bytes(), args.invert)
    render(bits, args.scale, args.grid).save(args.output)
    print(f"wrote {args.output}  scale={args.scale}x grid={args.grid}")


def cmd_ramp(args: argparse.Namespace) -> None:
    """Dither test card: a linear grey ramp plus flat patches."""
    grey = Image.new("L", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(grey)
    for x in range(WIDTH):
        draw.line([(x, 0), (x, 95)], fill=int(x / (WIDTH - 1) * 255))
    steps = 8
    for index in range(steps):
        value = round(index / (steps - 1) * 255)
        x0 = round(index * WIDTH / steps)
        x1 = round((index + 1) * WIDTH / steps)
        draw.rectangle([x0, 96, x1 - 1, HEIGHT - 1], fill=value)
    bits = halftone(grey, args.dither, 128)
    Path(args.output).write_bytes(pack(bits, args.invert))
    print(f"wrote {args.output}  dither={args.dither}")
    if args.preview:
        render(bits, args.scale, args.grid).save(args.preview)
        print(f"preview {args.preview}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--invert", action="store_true",
                        help="flip bit polarity (use if the panel shows a negative)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pack", help="image -> 5624-byte frame")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--dither", default="bayer4",
                   choices=["threshold", "bayer2", "bayer4", "bayer8", "floyd", "atkinson"])
    p.add_argument("--level", type=int, default=128, help="threshold mode cutoff")
    p.add_argument("--fit", default="cover", choices=["cover", "pad", "stretch"])
    p.add_argument("--preview", help="also write a PNG preview")
    p.add_argument("--scale", type=int, default=4)
    p.add_argument("--grid", action="store_true", help="overlay the 8px byte rows")
    p.set_defaults(func=cmd_pack)

    p = sub.add_parser("unpack", help="frame -> PNG preview")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--scale", type=int, default=4)
    p.add_argument("--grid", action="store_true")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("ramp", help="write a dither test card")
    p.add_argument("output")
    p.add_argument("--dither", default="bayer4",
                   choices=["threshold", "bayer2", "bayer4", "bayer8", "floyd", "atkinson"])
    p.add_argument("--preview")
    p.add_argument("--scale", type=int, default=4)
    p.add_argument("--grid", action="store_true")
    p.set_defaults(func=cmd_ramp)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
