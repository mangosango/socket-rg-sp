"""Write a Godot 4.7 PCK (format v4, unencrypted) from a directory tree.

Usage: python3 -I pack.py <src-dir> <out.pck>

Matches core/io/pck_packer.cpp: header, 32-byte aligned file data, then the
directory. File paths are relative to res://.
"""
import hashlib
import os
import struct
import sys

ALIGN = 32
GODOT_VERSION = (4, 7, 1)
PACK_REL_FILEBASE = 1 << 1


def pad(n, align):
    return (align - n % align) % align


def main(src, out):
    paths = sorted(
        os.path.relpath(os.path.join(root, name), src).replace(os.sep, "/")
        for root, _, names in os.walk(src)
        for name in names
    )
    entries = []
    with open(out, "wb") as f:
        f.write(struct.pack("<6I", 0x43504447, 4, *GODOT_VERSION, PACK_REL_FILEBASE))
        f.write(b"\0" * (8 + 8 + 64))  # File base, directory offset, reserved.
        f.write(b"\0" * pad(f.tell(), ALIGN))
        file_base = f.tell()
        for rel in paths:
            data = open(os.path.join(src, rel), "rb").read()
            entries.append((rel, f.tell() - file_base, len(data), hashlib.md5(data).digest()))
            f.write(data)
            f.write(b"\0" * pad(f.tell(), ALIGN))
        dir_offset = f.tell()
        f.write(struct.pack("<I", len(entries)))
        for rel, offset, size, md5 in entries:
            name = rel.encode("utf-8")
            name += b"\0" * pad(len(name), 4)
            f.write(struct.pack("<I", len(name)) + name + struct.pack("<QQ", offset, size) + md5 + struct.pack("<I", 0))
        f.seek(24)
        f.write(struct.pack("<QQ", file_base, dir_offset))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
