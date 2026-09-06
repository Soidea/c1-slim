# C1-Slim hardware notes

**[English](HARDWARE.md) · [简体中文](HARDWARE.zh-CN.md)**

Findings from driving the device directly, verified on real hardware. Every item here
cost a debugging round to discover; none of it is in any datasheet we could find.

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 LE · 1 core |
| Kernel | Linux 5.10.186 (Buildroot) |
| Panel | SEEKINK E0266A128 · 296 × 152 · 1 bpp · ~125 DPI · 60 × 31 mm |
| Audio | ALSA card `halley6`, codec **ES8326** — capture + playback |
| Keyboard | 40 keys: 30 matrix (`/dev/input/event0`) + 10 GPIO (`/dev/input/event1`) |
| ADB | adbd identifies as `product:occam model:Nexus_4 device:mako` |

`halley6` is the name of Ingenic's own X1600 reference board, so the vendor stayed close
to the reference design — Ingenic's Halley6 material is likely to apply.

---

## Display

### Framebuffer layout — strip-major, not column-major

```
byte = buf[(y >> 3) * 296 + x]
bit  = 7 - (y & 7)
1    = black
```

The frame is 19 horizontal strips of 8 pixels. Each strip is 296 consecutive bytes, one
per column; each byte holds 8 vertically-stacked pixels of that strip, MSB topmost.

Authoritative source is `c1_display_frame_set_pixel()` in `src/display/frame.c`:

```c
offset = (y / C1_DISPLAY_STRIP_HEIGHT) * C1_DISPLAY_WIDTH + x;
mask   = (uint8_t)(0x80U >> (y % C1_DISPLAY_STRIP_HEIGHT));
```

**The trap:** column-major (296 columns × 19 bytes) and strip-major (19 strips × 296
bytes) both total 5,624 bytes. A size check cannot tell them apart, and a pack/unpack
round-trip test passes either way because it is self-consistent. We shipped a
column-major implementation whose tests were all green; on the device it rendered as
vertical stripes. Verify against the source or the panel, never against your own
round-trip.

### `/dev/epaper_lcd` needs one single `write()`

The driver treats **every `write()` call as the start of a new frame**. A partial or
chunked write renders only the last chunk, placed at the top-left corner.

```sh
# WRONG - cat may split the write; tail of the frame appears at the top,
#         with a horizontal offset if the chunk boundary is not strip-aligned
cat frame.bin > /dev/epaper_lcd

# RIGHT - one write() syscall of exactly 5624 bytes
dd if=frame.bin of=/dev/epaper_lcd bs=5624 count=1
```

C1ancher is unaffected because it issues a single `write(fd, frame, 5624)`.

### The framebuffer cannot be read back

`/dev/epaper_lcd` is a write-only character device (major 10, minor 61): `read()` is not
implemented and returns 0 bytes. There is no `/dev/fb*` on the device.

To capture the screen, patch the renderer to tee each frame — see
[`patches/display-shadow.patch`](patches/display-shadow.patch), which writes every frame
to `/dev/shm/c1-screen.bin` (tmpfs, so no eMMC wear) after a successful panel write.
`adb pull` that file and you have a pixel-exact screenshot.

### sysfs

`/sys/devices/platform/e0266a128/epaper/`

| Attribute | Mode | Notes |
|---|---|---|
| `refresh` | `--w-------` | write `0` to trigger |
| `refresh_cnt` | `-r--r--r--` | monotonic counter — useful for timing refreshes objectively |
| `refresh_max` | `-rw-r--r--` | driver refresh-policy limit |
| `fast_refresh_only` | `-rw-r--r--` | `1` selects fast (partial-waveform) refresh |

### Design consequences

The binding constraint is **refresh time, not resolution or colour depth**. Static
content is free and permanent; changing pixels is what costs.

- 152 = 19 × 8 exactly, so any element whose vertical extent starts on a multiple of 8
  blits as plain byte stores. Off-grid placement needs shift+mask.
- A 1 px horizontal line touches 296 bytes; a 1 px vertical line touches 19 bytes in a
  single strip. Vertical elements are far cheaper.
- Use **ordered (Bayer) dithering, not error diffusion**, for UI. Ordered patterns are
  spatially fixed, so a small content change flips only the pixels that changed. Floyd–
  Steinberg re-randomises whole regions and ghosts badly on e-paper. Error diffusion is
  still right for photographs.
- At ~125 DPI a 1 px rule is about 0.2 mm — it reads as a hairline, not as a jaggy edge.
  This panel supports finer detail than the 72 DPI classic-Mac aesthetic suggests.

---

## Audio

```
card 0: halley6
  capture  device 0: i2s-ecodec es8326.1-0018-0
  capture  device 1: i2s-tloop dump_pcm_codec-1
  playback device 0: i2s-ecodec es8326.1-0018-0
```

Microphone and speaker both work. Verified capture:

```sh
arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav
```

16 kHz mono S16LE is the standard input format for speech recognition, so the mic feeds
an ASR pipeline with no resampling.

Measured on one sample of ordinary speech: peak −0.83 dBFS, RMS −23.7 dBFS, crest factor
22.8 dB. The crest factor is in the normal range for speech rather than for noise, but
the peak is under 1 dB from clipping — **capture gain is set very hot**. Trim it via
`amixer -c 0` if you care about ASR accuracy, since clipping hurts more than a low level.

`scripts/device-control.sh` snapshots and restores mixer state with `alsactl … 0`.

---

## Keyboard

Full 26-letter QWERTY plus Shift, Space, Enter, Delete, arrows, Back, OK, Home, Wakeup
and volume keys. C1ancher maps OK-hold + letter to Ctrl+A–Z, OK click to Tab and Back to
Esc, which is enough to drive `vi`, `top`, `less` and an interactive `ssh` session in its
built-in terminal.

Scan codes are in [`config/c1-slim/keyboard.csv`](config/c1-slim/keyboard.csv).

---

## Related work

The device-specific ecosystem is essentially just C1ancher, but the **SoC** ecosystem is
not. X1600 is XBurst1, so these are the right family:

- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) — kernel tree; X1600 marked partially supported
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) — U-Boot for XBurst1
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) — USB DFU / Ingenic Cloner flashing tools
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) — per-SoC cloner trigger profiles
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) — large Ingenic firmware communities

If the X1600 BootROM exposes the Cloner USB recovery mode, a bricked eMMC is recoverable
and the risk calculus for touching U-Boot changes completely. **Not yet verified on this
device** — worth establishing before going deeper.
