#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Host reference for the context-switch stress in tests/ktest_main.ad.

stress_mix() there does 64-bit multiply, divide and modulo and double-precision
arithmetic in one loop; this is the same loop in Python (exact integers,
IEEE-754 binary64 floats).  The expected checksums in the test were copied from
this script's output.  Only exactly representable float constants are used, so
the result does not depend on how a literal is parsed.
"""
import struct

M = (1 << 64) - 1

def bits(d):
    return struct.unpack("<Q", struct.pack("<d", d))[0]

def stress_mix(seed, n):
    x, acc, xs = seed, 1.0, 0
    for i in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & M
        q = x // (i + 3)
        r = x % 1000003
        xs ^= q
        acc = acc * 0.5 + float(r) / float(i + 1)
    return xs ^ bits(acc)

if __name__ == "__main__":
    for seed in (1, 2, 3, 4, 5, 6):
        print("stress_mix(%d, 12000) = 0x%016x" % (seed, stress_mix(seed, 12000)))
