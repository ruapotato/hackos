#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""panel2png.py STREAM OUTDIR [--font font8x8_basic.h] [--yscale N] [--keep N]

The host side of HackOS's fake e-paper panel (drivers/display/fakepanel.ad).
STREAM is what the panel's byte sink received (QEMU: the second UART,
written to a file).  The records are replayed into the image a panel would
hold, and after every refresh that image is written to OUTDIR as
frame-NNNN.png (with --keep N only the last N, plus last.png always): a
1-bit or 2-bit greyscale PNG, white paper, black ink.

Printed, one line per record:  #n F|P|S bpp x y w h  sum ok|BAD
                               (a full refresh also: levels a,b,..: the pixel
                               values found in it)
then a summary line:           records: full N partial N sleep N bad N
With --font, the text on the final image is read back by matching every
8 x (8 * yscale) cell against the font (also inverted), and printed after a
line "text:" -- rows with trailing blanks removed.  That is an independent
check of the whole path: character -> glyph -> frame buffer -> refresh
records -> image.

Every PNG written is read back with this file's own decoder (chunk CRCs,
zlib, filter 0) and compared with the image; a mismatch is an error.
Standard library only.  Exit status 0, or 1 for a malformed stream.
"""
import re
import struct
import sys
import zlib


def png_write(path, w, h, bpp, rows):
    """rows: list of bytes, packed MSB first, our sense (0 = white)."""
    raw = bytearray()
    for r in rows:
        raw.append(0)                                   # filter: none
        raw.extend(b ^ 0xFF for b in r)                 # PNG: 0 is black
        # the padding bits at the end of a row are inverted too; harmless
    def chunk(kind, data):
        c = struct.pack('>I', len(data)) + kind + data
        return c + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, bpp, 0, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def png_read(path):
    """-> (w, h, bpp, rows in our sense).  Greyscale, filter 0 only."""
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos = 8
    idat = b''
    hdr = None
    while pos < len(d):
        n, kind = struct.unpack('>I4s', d[pos:pos + 8])
        data = d[pos + 8:pos + 8 + n]
        crc, = struct.unpack('>I', d[pos + 8 + n:pos + 12 + n])
        assert crc == zlib.crc32(kind + data) & 0xFFFFFFFF, 'chunk CRC'
        if kind == b'IHDR':
            hdr = struct.unpack('>IIBBBBB', data)
        elif kind == b'IDAT':
            idat += data
        pos += 12 + n
    w, h, bpp, ctype = hdr[0], hdr[1], hdr[2], hdr[3]
    assert ctype == 0 and bpp in (1, 2)
    raw = zlib.decompress(idat)
    stride = (w * bpp + 7) // 8
    rows = []
    for y in range(h):
        assert raw[y * (stride + 1)] == 0, 'filter'
        rows.append(bytes(b ^ 0xFF for b in raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)]))
    return w, h, bpp, rows


def get(rows, bpp, x, y):
    if bpp == 1:
        return (rows[y][x >> 3] >> (7 - (x & 7))) & 1
    return (rows[y][x >> 2] >> (6 - ((x & 3) << 1))) & 3


def load_font(path):
    glyphs = []
    for m in re.finditer(r'\{\s*((?:0x[0-9A-Fa-f]{2}\s*,?\s*){8})\}', open(path).read()):
        glyphs.append(tuple(int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{2})', m.group(1))))
    assert len(glyphs) >= 128, 'font table'
    return glyphs[:128]


def read_text(rows, w, h, bpp, glyphs, yscale):
    """The image as text; '?' for a cell that is no glyph, either way up."""
    ink = (1 << bpp) - 1
    lookup = {}
    for c in range(32, 127):
        lookup.setdefault(glyphs[c], chr(c))
    out = []
    for cy in range(h // (8 * yscale)):
        line = ''
        for cx in range(w // 8):
            g = []
            ok = True
            for r in range(8):
                bits = 0
                for i in range(8):
                    v = get(rows, bpp, cx * 8 + i, (cy * 8 + r) * yscale)
                    for s in range(1, yscale):
                        if get(rows, bpp, cx * 8 + i, (cy * 8 + r) * yscale + s) != v:
                            ok = False
                    if v == ink:
                        bits |= 1 << i
                    elif v != 0:
                        ok = False
                g.append(bits)
            g = tuple(g)
            inv = tuple(b ^ 0xFF for b in g)
            if ok and g in lookup:
                line += lookup[g]
            elif ok and inv in lookup:
                line += lookup[inv] if lookup[inv] != ' ' else '#'      # an inverted blank: the cursor
            else:
                line += '?'
        out.append(line.rstrip())
    return out


def main():
    args = sys.argv[1:]
    font = None
    yscale = 2
    keep = None
    pos = []
    while args:
        a = args.pop(0)
        if a == '--font':
            font = args.pop(0)
        elif a == '--yscale':
            yscale = int(args.pop(0))
        elif a == '--keep':
            keep = int(args.pop(0))
        else:
            pos.append(a)
    stream, outdir = pos
    d = open(stream, 'rb').read()
    p = 0
    n = 0
    img = None
    iw = ih = ibpp = 0
    counts = {'F': 0, 'P': 0, 'S': 0}
    bad = 0
    frames = []
    while True:
        p = d.find(b'\x1bPNL', p)
        if p < 0:
            break
        if p + 14 > len(d):
            print('truncated header'); bad += 1; break
        kind = chr(d[p + 4])
        bpp = d[p + 5]
        x, y, w, h = struct.unpack('<HHHH', d[p + 6:p + 14])
        rowbytes = (w * bpp + 7) // 8
        end = p + 14 + rowbytes * h + 2
        if kind not in counts or bpp not in (1, 2) or end > len(d):
            print(f'#{n} malformed record at byte {p}'); bad += 1; p += 4; continue
        payload = d[p + 14:end - 2]
        ssum, = struct.unpack('<H', d[end - 2:end])
        good = (sum(payload) & 0xFFFF) == ssum
        if not good:
            bad += 1
        counts[kind] += 1
        note = ''
        if kind == 'F':
            iw, ih, ibpp = w, h, bpp
            img = [bytearray(payload[r * rowbytes:(r + 1) * rowbytes]) for r in range(h)]
            note = ' levels ' + ','.join(str(v) for v in sorted({get(img, bpp, xx, yy) for yy in range(0, h, 7) for xx in range(0, w, 5)}))
        print(f"#{n} {kind} {bpp} {x} {y} {w} {h} sum {'ok' if good else 'BAD'}{note}")
        if kind == 'F':
            pass
        elif kind == 'P':
            if img is None or bpp != ibpp or x + w > iw or y + h > ih or (x * bpp) % 8:
                print(f'#{n} partial refresh outside the panel, or before a full one'); bad += 1
            else:
                off = x * bpp // 8
                for r in range(h):
                    img[y + r][off:off + rowbytes] = payload[r * rowbytes:(r + 1) * rowbytes]
        if kind in 'FP' and img is not None:
            frames.append([bytes(r) for r in img])
            if keep is not None and len(frames) > keep:
                frames.pop(0)
        n += 1
        p = end
    first = n - counts['S'] - len(frames)
    for i, fr in enumerate(frames):
        name = f'{outdir}/frame-{first + i:04d}.png'
        png_write(name, iw, ih, ibpp, fr)
        if png_read(name) != (iw, ih, ibpp, fr):
            print(f'{name}: read back differently'); bad += 1
    if frames:
        png_write(f'{outdir}/last.png', iw, ih, ibpp, frames[-1])
    print(f"records: full {counts['F']} partial {counts['P']} sleep {counts['S']} bad {bad}")
    if frames:
        levels = sorted({get(frames[-1], ibpp, xx, yy) for yy in range(0, ih, 7) for xx in range(0, iw, 5)})
        print(f'image: {iw} x {ih}, {ibpp} bit(s) per pixel, levels in the last frame: {levels}')
    if font and frames:
        print('text:')
        for line in read_text(frames[-1], iw, ih, ibpp, load_font(font), yscale):
            print(line)
    sys.exit(1 if bad else 0)


main()
