#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# mkuf2.py --family ID IN.hex OUT.uf2
#
# Intel HEX -> UF2 (https://github.com/microsoft/uf2, README "File format"),
# the format Adafruit's nRF52 bootloader accepts on its USB drive:
#   512-byte blocks: magicStart0 0x0A324655, magicStart1 0x9E5D5157,
#   flags 0x00002000 (familyID present), targetAddr, payloadSize 256,
#   blockNo, numBlocks, familyID, 476 data bytes (256 used, rest 0),
#   magicEnd 0x0AB16F30; all little-endian.
# One block per 256-byte-aligned page that holds any byte of the image;
# bytes of such a page that the image does not define are 0xFF (erased
# flash).  The bootloader writes a block to targetAddr if it lies in the
# application area and skips blocks below it (MBR); tests/nrf52/check_uf2.py
# re-reads the file and checks every block against the ELF.
import struct
import sys

MAGIC0, MAGIC1, MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
FLAG_FAMILY = 0x00002000
PAGE = 256


def read_hex(path):
    mem = {}
    base = 0
    for n, line in enumerate(open(path), 1):
        line = line.strip()
        if not line:
            continue
        if line[0] != ':':
            sys.exit(f"{path}:{n}: not an Intel HEX record")
        rec = bytes.fromhex(line[1:])
        if sum(rec) & 0xFF:
            sys.exit(f"{path}:{n}: checksum error")
        cnt, addr, typ = rec[0], (rec[1] << 8) | rec[2], rec[3]
        data = rec[4:4 + cnt]
        if len(data) != cnt:
            sys.exit(f"{path}:{n}: short record")
        if typ == 0:
            for i, b in enumerate(data):
                a = base + addr + i
                if a in mem:
                    sys.exit(f"{path}:{n}: address 0x{a:08x} defined twice")
                mem[a] = b
        elif typ == 1:
            break
        elif typ == 2:
            base = int.from_bytes(data, 'big') << 4
        elif typ == 4:
            base = int.from_bytes(data, 'big') << 16
        elif typ in (3, 5):
            pass            # start address records: the bootloader ignores them
        else:
            sys.exit(f"{path}:{n}: record type {typ}")
    return mem


def main():
    args = sys.argv[1:]
    if len(args) != 4 or args[0] != '--family':
        sys.exit(__doc__ if __doc__ else "usage: mkuf2.py --family ID IN.hex OUT.uf2")
    family = int(args[1], 0)
    mem = read_hex(args[2])
    if not mem:
        sys.exit("empty image")
    pages = sorted({a // PAGE * PAGE for a in mem})
    out = bytearray()
    for i, p in enumerate(pages):
        data = bytes(mem.get(p + j, 0xFF) for j in range(PAGE))
        blk = struct.pack('<8I', MAGIC0, MAGIC1, FLAG_FAMILY, p, PAGE, i, len(pages), family)
        blk += data + bytes(476 - PAGE) + struct.pack('<I', MAGIC_END)
        assert len(blk) == 512
        out += blk
    open(args[3], 'wb').write(out)
    print(f"mkuf2: {len(pages)} blocks, 0x{pages[0]:08x}..0x{pages[-1] + PAGE:08x}, family 0x{family:08x}")


main()
