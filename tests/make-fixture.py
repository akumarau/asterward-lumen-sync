#!/usr/bin/env python3
"""Build a small fake icloudpd output tree for offline tests.

Usage:
  make-fixture.py ORIGINALS_DIR             full fixture library
  make-fixture.py --download ORIGINALS_DIR  files a stub icloudpd "downloads"

Standard library only. The images are real 8x8 JPEG, PNG and TIFF files,
embedded below. TIFF content stands in for raw, because ARW is TIFF based and
exiftool reads it that way.

The library covers the cases the phase scripts must handle:

  * Live Photo pair: IMG_0001.JPG + IMG_0001_HEVC.MOV
  * Standalone video with no companion photo: IMG_0002.MOV
  * Exact content duplicate across two months
  * Raw file that needs a sidecar
  * PNG screenshot
  * exFAT noise: AppleDouble ._ files, .DS_Store, an interrupted .part file
"""

import base64
import os
import sys

JPEG_RED = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcU"
    "FhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
    "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDy6iii"
    "vmj9tP/Z"
)
JPEG_GREEN = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcU"
    "FhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
    "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCvRRRX"
    "5ufkh//Z"
)
JPEG_NEW = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcU"
    "FhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
    "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5Xooo"
    "piP/2Q=="
)
JPEG_SONY = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcU"
    "FhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
    "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDyyiii"
    "vIPTP//Z"
)
PNG_GREY = (
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFklEQVR4XmOsqKhgwAaYsIoyMAxS"
    "CQAdhwF4I7KkBgAAAABJRU5ErkJggg=="
)
TIFF_BLUE = (
    "SUkqAAgAAAAKAAABBAABAAAACAAAAAEBBAABAAAACAAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAA"
    "AAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAACAAAABcBBAABAAAA"
    "wAAAABwBAwABAAAAAQAAAAAAAAAIAAgACAAKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgK"
    "CsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgK"
    "CsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgK"
    "CsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsgKCsg="
)
TIFF_NEW = (
    "SUkqAAgAAAAKAAABBAABAAAACAAAAAEBBAABAAAACAAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAA"
    "AAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAACAAAABcBBAABAAAA"
    "wAAAABwBAwABAAAAAQAAAAAAAAAIAAgACAAEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYE"
    "BQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYE"
    "BQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYE"
    "BQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQYEBQY="
)


def put(path, b64):
    with open(path, "wb") as fh:
        fh.write(base64.b64decode(b64))


def write(path, data):
    with open(path, "wb") as fh:
        fh.write(data)


def library(root):
    m1 = os.path.join(root, "2024", "2024-03")
    m2 = os.path.join(root, "2024", "2024-04")
    for d in (m1, m2):
        os.makedirs(d, exist_ok=True)

    # Live Photo pair, icloudpd default MOV naming adds _HEVC.
    put(os.path.join(m1, "IMG_0001.JPG"), JPEG_RED)
    write(os.path.join(m1, "IMG_0001_HEVC.MOV"), b"fake-live-photo-video-0001")

    # A real video with no companion still. Must never be treated as Live Photo.
    write(os.path.join(m1, "IMG_0002.MOV"), b"fake-standalone-video-0002")

    # Exact duplicate in a later month.
    put(os.path.join(m1, "IMG_0003.JPG"), JPEG_GREEN)
    put(os.path.join(m2, "IMG_0003 copy.JPG"), JPEG_GREEN)

    # icloudpd size-suffix copy of the same asset, as seen on the real drive.
    # Dedupe must keep the plain name, which is what icloudpd looks for.
    put(os.path.join(m2, "DSC00042.JPG"), JPEG_SONY)
    put(os.path.join(m2, "DSC00042-691516.JPG"), JPEG_SONY)

    # Raw stand-in and a PNG.
    put(os.path.join(m2, "DSC_0004.ARW"), TIFF_BLUE)
    put(os.path.join(m2, "Screenshot_0005.PNG"), PNG_GREY)

    # exFAT and macOS noise that must never be counted or processed.
    write(os.path.join(m1, "._IMG_0001.JPG"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(m2, "._IMG_0003 copy.JPG"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(m2, "._DSC_0004.ARW"), b"\x00\x05\x16\x07appledouble")
    write(os.path.join(root, ".DS_Store"), b"dsstore")
    write(os.path.join(m2, "IMG_0006.JPG.part"), b"half")


def download(root):
    d = os.path.join(root, "2024", "2024-05")
    os.makedirs(d, exist_ok=True)
    put(os.path.join(d, "IMG_0100.JPG"), JPEG_NEW)
    put(os.path.join(d, "DSC_0101.ARW"), TIFF_NEW)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--download":
        download(sys.argv[2])
    elif len(sys.argv) == 2:
        library(sys.argv[1])
    else:
        sys.exit(__doc__)
