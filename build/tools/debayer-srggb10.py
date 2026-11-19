#!/usr/bin/env python3
"""debayer-srggb10.py — convert a raw IMX219 frame to a viewable JPEG.

Field-verified on CPZ-Alpine v0.15 (2026-11-19): the CardputerZero's
IMX219 captures via unicam as pRAA (MIPI-packed 10-bit Bayer SRGGB) at
3280x2464 with 4128 bytes/line (820 packed groups of 5 bytes + 28 bytes
padding). Full 10-bit dynamic range observed on hardware (min 0,
max 1023).

Capture on the device (v4l-utils, kept across reflashes by the
persistence pkglist):

    v4l2-ctl -d /dev/video0 \\
        --set-fmt-video=width=3280,height=2464,pixelformat=pRAA
    v4l2-ctl -d /dev/video0 \\
        --stream-mmap=4 --stream-count=1 --stream-to=/tmp/frame.raw

Convert on any machine with numpy + pillow:

    python3 debayer-srggb10.py /tmp/frame.raw /tmp/camera-test.jpg

The debayer is nearest-neighbour half-resolution (1640x1232) — plenty
for verification; the sensor path is the thing under test.
"""

import sys
import numpy as np
from PIL import Image

W, H, BPL = 3280, 2464, 4128          # pRAA geometry, read back from the device


def main(src, dst):
    raw = np.fromfile(src, dtype=np.uint8, count=BPL * H)
    lines = raw.reshape(H, BPL)

    # 4 samples per 5 bytes (MIPI 10-bit packing); 820 groups/line + pad
    b = lines[:, :4100].reshape(H, 820, 5).astype(np.uint32)
    v = np.zeros((H, 820, 4), dtype=np.uint16)
    v[..., 0] = (b[..., 0] << 2) | (b[..., 1] >> 6)
    v[..., 1] = ((b[..., 1] & 0x3F) << 4) | (b[..., 2] >> 4)
    v[..., 2] = ((b[..., 2] & 0x0F) << 6) | (b[..., 3] >> 2)
    v[..., 3] = ((b[..., 3] & 0x03) << 8) | b[..., 4]
    img = v.reshape(H, 3280).astype(np.float32)
    print(f"10-bit stats: min {int(img.min())} max {int(img.max())} "
          f"mean {round(float(img.mean()), 1)}")

    # SRGGB: R at even/even; G at even/odd + odd/even; B at odd/odd
    R = img[0::2, 0::2]
    G = (img[0::2, 1::2] + img[1::2, 0::2]) / 2.0
    B = img[1::2, 1::2]
    rgb = np.stack([R, G, B], axis=-1)

    mean_all = rgb.mean()              # gray-world white balance
    for c in range(3):
        m = rgb[..., c].mean()
        if m > 0:
            rgb[..., c] *= mean_all / m

    rgb = np.clip(rgb * (255.0 / max(rgb.max(), 1.0)), 0, 255)
    out = Image.fromarray(rgb.astype(np.uint8))
    out = out.resize((1024, int(1024 * out.height / out.width)),
                     Image.LANCZOS)
    out.save(dst, quality=88)
    print(f"saved {dst} {out.size}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])