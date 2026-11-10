#!/usr/bin/env python3
"""Build a small fake icloudpd output tree for offline tests.

Usage: make-fixture.py ORIGINALS_DIR

Creates real, tiny JPEG, PNG and TIFF files (TIFF content stands in for raw,
because ARW and DNG are TIFF based and exiftool can read them that way).
The tree covers the cases the phase scripts must handle:

  * Live Photo pair: IMG_0001.JPG + IMG_0001_HEVC.MOV
  * Standalone video with no companion photo: IMG_0002.MOV
  * Exact content duplicate across two months
  * Raw file that needs a sidecar
  * PNG screenshot
  * exFAT noise: AppleDouble ._ files, .DS_Store, an interrupted .part file
"""

import os
import sys

from PIL import Image


def jpeg(path, colour):
    Image.new("RGB", (8, 8), colour).save(path, "JPEG", quality=80)


def png(path, colour):
    Image.new("RGB", (8, 8), colour).save(path, "PNG")


def tiff(path, colour):
    Image.new("RGB", (8, 8), colour).save(path, "TIFF")


def write(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def main(root):
    m1 = os.path.join(root, "2024", "2024-03")
    m2 = os.path.join(root, "2024", "2024-04")
    for d in (m1, m2):
        os.makedirs(d, exist_ok=True)

    # Live Photo pair, icloudpd default MOV naming adds _HEVC.
    jpeg(os.path.join(m1, "IMG_0001.JPG"), (200, 10, 10))
    write(os.path.join(m1, "IMG_0001_HEVC.MOV"), b"fake-live-photo-video-0001")

    # A real video with no companion still. Must never be treated as Live Photo.
    write(os.path.join(m1, "IMG_0002.MOV"), b"fake-standalone-video-0002")

    # Exact duplicate in a later month.
    jpeg(os.path.join(m1, "IMG_0003.JPG"), (10, 200, 10))
    with open(os.path.join(m1, "IMG_0003.JPG"), "rb") as fh:
        write(os.path.join(m2, "IMG_0003 copy.JPG"), fh.read())

    # Raw stand-in and a PNG.
    tiff(os.path.join(m2, "DSC_0004.ARW"), (10, 10, 200))
    png(os.path.join(m2, "Screenshot_0005.PNG"), (120, 120, 120))

    # exFAT and macOS noise that must never be counted or processed.
    write(os.path.join(m1, "._IMG_0001.JPG"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(m2, "._IMG_0003 copy.JPG"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(m2, "._DSC_0004.ARW"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(root, ".DS_Store"), b"dsstore")
    write(os.path.join(m2, "IMG_0006.JPG.part"), b"half")


if __name__ == "__main__":
    main(sys.argv[1])
