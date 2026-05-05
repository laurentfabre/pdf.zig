#!/usr/bin/env python3
"""
PR-W10b — minimal sRGB v2 IEC61966-2.1 ICC profile generator.

Why this exists. The canonical sRGB profiles shipped by OS vendors and
icc.opensuse.org carry per-vendor licensing. We hand-roll a minimal but
spec-conformant 9-tag display profile so the asset is unambiguously
redistributable.

What it emits. A 480-byte ICC v2 monitor-class RGB-to-XYZ profile with:
    desc, cprt, wtpt, rXYZ, gXYZ, bXYZ, rTRC (=gTRC=bTRC -> shared curv)

Tag values: D50-adapted matrix per IEC 61966-2.1 + Bradford CAT to D50.
Tone curve: single-gamma 2.2 (curv with count=1, u8Fixed8=563).

Output target: src/assets/srgb.icc (relative to this script's repo root).
"""
import os
import struct
import sys


def s15f16(x: float) -> int:
    return int(round(x * 65536.0))


def be32(x: int) -> bytes:
    return struct.pack(">I", x & 0xFFFFFFFF)


def be16(x: int) -> bytes:
    return struct.pack(">H", x & 0xFFFF)


def s32(x: int) -> bytes:
    return struct.pack(">i", x)


def XYZ(triple):
    out = b"XYZ \x00\x00\x00\x00"
    for v in triple:
        out += s32(s15f16(v))
    return out


def desc_tag(s: str) -> bytes:
    sb = s.encode("ascii") + b"\x00"
    body = b"desc" + b"\x00\x00\x00\x00"
    body += be32(len(sb))
    body += sb
    body += be32(0)  # unicode language
    body += be32(0)  # unicode count
    body += be16(0) + bytes([0]) + bytes(67)  # ScriptCode (mac-only)
    return body


def text_tag(s: str) -> bytes:
    return b"text" + b"\x00\x00\x00\x00" + s.encode("ascii") + b"\x00"


def curv_gamma_22() -> bytes:
    return b"curv" + b"\x00\x00\x00\x00" + be32(1) + be16(563)


def align4(n: int) -> int:
    return (n + 3) & ~3


def build() -> bytes:
    rXYZ = (0.4360747, 0.2225485, 0.0139322)
    gXYZ = (0.3850649, 0.7168704, 0.0971045)
    bXYZ = (0.1430804, 0.0606169, 0.7141733)
    wtpt = (0.96420288, 1.0, 0.82490540)  # D50

    curv = curv_gamma_22()
    tags = [
        (b"desc", desc_tag("sRGB IEC61966-2.1")),
        (b"cprt", text_tag("No copyright, use freely.")),
        (b"wtpt", XYZ(wtpt)),
        (b"rXYZ", XYZ(rXYZ)),
        (b"gXYZ", XYZ(gXYZ)),
        (b"bXYZ", XYZ(bXYZ)),
        (b"rTRC", curv),
        (b"gTRC", curv),
        (b"bTRC", curv),
    ]

    HEADER = 128
    TAG_TABLE = 4 + len(tags) * 12

    body_offsets: dict[bytes, int] = {}
    body_order: list[tuple[int, bytes]] = []
    cursor = align4(HEADER + TAG_TABLE)

    layout: list[tuple[bytes, int, int]] = []
    for sig, body in tags:
        if body in body_offsets:
            off = body_offsets[body]
        else:
            off = cursor
            body_offsets[body] = off
            body_order.append((off, body))
            cursor = align4(cursor + len(body))
        layout.append((sig, off, len(body)))

    total_size = cursor

    hdr = bytearray(HEADER)
    hdr[0:4] = be32(total_size)
    hdr[4:8] = b"pdfz"
    hdr[8:12] = bytes([2, 16, 0, 0])  # version 2.4 (legal v2 minor)
    hdr[12:16] = b"mntr"
    hdr[16:20] = b"RGB "
    hdr[20:24] = b"XYZ "
    hdr[36:40] = b"acsp"
    hdr[40:44] = b"APPL"
    hdr[64:68] = be32(1)  # rendering intent: relative colorimetric
    # PCS illuminant at 68: D50
    hdr[68:72] = s32(s15f16(0.9642))
    hdr[72:76] = s32(s15f16(1.0))
    hdr[76:80] = s32(s15f16(0.8249))
    hdr[80:84] = b"pdfz"

    tt = be32(len(tags))
    for sig, off, sz in layout:
        tt += sig + be32(off) + be32(sz)

    body_section = bytearray(total_size - HEADER - len(tt))
    for off, body in body_order:
        rel = off - (HEADER + len(tt))
        body_section[rel:rel + len(body)] = body

    profile = bytes(hdr) + tt + bytes(body_section)
    assert len(profile) == total_size
    assert profile[36:40] == b"acsp"
    assert struct.unpack(">I", profile[0:4])[0] == len(profile)
    return profile


def main() -> int:
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "src", "assets")
    out_dir = os.path.normpath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "srgb.icc")

    blob = build()
    with open(out, "wb") as f:
        f.write(blob)
    print(f"wrote {out} ({len(blob)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
