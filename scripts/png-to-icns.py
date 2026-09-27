#!/usr/bin/env python3
"""Wrap a 1024px PNG in the modern ICNS 1024px image chunk."""

import os
import struct
import sys
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICNS_IMAGE_1024 = b"ic10"


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError("input is not a valid PNG")
    return struct.unpack(">II", data[16:24])


def write_icns(source: Path, target: Path) -> None:
    png = source.read_bytes()
    if png_dimensions(png) != (1024, 1024):
        raise ValueError("ICNS source image must be 1024 by 1024 pixels")

    image_chunk = ICNS_IMAGE_1024 + struct.pack(">I", len(png) + 8) + png
    icon = b"icns" + struct.pack(">I", len(image_chunk) + 8) + image_chunk
    temporary_target = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        temporary_target.write_bytes(icon)
        os.replace(temporary_target, target)
    finally:
        temporary_target.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: png-to-icns.py SOURCE.png TARGET.icns", file=sys.stderr)
        return 2
    try:
        write_icns(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError) as error:
        print(f"cannot create ICNS file: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
