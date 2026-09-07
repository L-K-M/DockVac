#!/usr/bin/env python3
"""Derive Resources/AppIcon.icns from media-sources/icon.png.

The source artwork is a square, opaque render. macOS app icons sit on the
Big Sur icon grid: a 1024 pt canvas whose rounded square occupies 824 pt with
a corner radius of roughly 22.5 percent, plus a soft drop shadow. This script
masks the artwork onto that grid and writes a PNG-payload ICNS container, so
it runs anywhere Pillow is available (no iconutil needed).

Usage: scripts/make-icon.py [--preview build/icon-preview.png]
"""

import argparse
import struct
import sys
from io import BytesIO
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - guidance for contributors
    sys.exit("Pillow is required: python3 -m pip install pillow")

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SOURCE = REPOSITORY_ROOT / "media-sources" / "icon.png"
OUTPUT = REPOSITORY_ROOT / "Resources" / "AppIcon.icns"

CANVAS = 1024
ARTWORK = 824
CORNER_RADIUS = 185
SHADOW_OFFSET_Y = 12
SHADOW_BLUR = 22
SHADOW_ALPHA = 110
SUPERSAMPLE = 4

# ICNS element types keyed by pixel size. All of them accept PNG payloads.
ICNS_TYPES = {
    16: [b"icp4"],
    32: [b"icp5", b"ic11"],
    64: [b"icp6", b"ic12"],
    128: [b"ic07"],
    256: [b"ic08", b"ic13"],
    512: [b"ic09", b"ic14"],
    1024: [b"ic10"],
}


def rounded_mask(size, radius, scale):
    large = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(large).rounded_rectangle(
        [0, 0, size * scale - 1, size * scale - 1], radius=radius * scale, fill=255
    )
    return large.resize((size, size), Image.LANCZOS)


def compose_master(source_path):
    source = Image.open(source_path).convert("RGB")
    side = min(source.size)
    left = (source.width - side) // 2
    top = (source.height - side) // 2
    artwork = source.crop((left, top, left + side, top + side)).resize(
        (ARTWORK, ARTWORK), Image.LANCZOS
    )

    mask = rounded_mask(ARTWORK, CORNER_RADIUS, SUPERSAMPLE)
    tile = Image.new("RGBA", (ARTWORK, ARTWORK), (0, 0, 0, 0))
    tile.paste(artwork, (0, 0), mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - ARTWORK) // 2

    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_tile = Image.new("RGBA", (ARTWORK, ARTWORK), (0, 0, 0, SHADOW_ALPHA))
    shadow.paste(shadow_tile, (offset, offset + SHADOW_OFFSET_Y), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))

    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(tile, (offset, offset))
    return canvas


def png_bytes(image):
    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def build_icns(master):
    elements = []
    for size, types in sorted(ICNS_TYPES.items()):
        rendition = master if size == CANVAS else master.resize((size, size), Image.LANCZOS)
        payload = png_bytes(rendition)
        for icns_type in types:
            elements.append(icns_type + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(elements)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--preview", type=Path, help="also write a 512 px PNG preview")
    arguments = parser.parse_args()

    master = compose_master(SOURCE)
    OUTPUT.write_bytes(build_icns(master))
    print(OUTPUT)

    if arguments.preview:
        arguments.preview.parent.mkdir(parents=True, exist_ok=True)
        master.resize((512, 512), Image.LANCZOS).save(arguments.preview)
        print(arguments.preview)


if __name__ == "__main__":
    main()
