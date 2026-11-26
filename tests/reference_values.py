#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Host reference for the constants demo/main.ad checks against.

Run it to print them; the demo's expected values were copied from this output.
Python floats are IEEE-754 binary64 and its integers are exact, so these are
what a correct double-precision FPU and correct 64-bit integer helpers give.
"""
import struct

def bits(d):
    return struct.unpack("<Q", struct.pack("<d", d))[0]

M = 2**64 - 1
a, b, c = 0x123456789ABCDEF0, 0xFEDCBA987, 1000000007
print("u64 a*b low64      ", hex((a * b) & M))
print("u64 a/c, a%c       ", a // c, a % c)
print("u64 a/b, a%b       ", a // b, a % b)
sa, sb = -1234567890123456789, 987654321
q, r = abs(sa) // sb, abs(sa) % sb          # C semantics: truncate toward zero
print("i64 sa/sb, sa%sb   ", -q, -r)
s = 1.5 * 2.25 + 1.5 / 2.25 - 0.125
print("f64 expr           ", repr(s), hex(bits(s)))
g = 2.0
for _ in range(60):
    g = 0.5 * (g + 2.0 / g)
print("f64 Newton sqrt(2) ", repr(g), hex(bits(g)), "err", abs(g * g - 2.0))
acc = 0.0
for k in range(1000, 0, -1):
    acc = acc + 1.0 / (float(k) * float(k))
print("f64 sum 1/k^2      ", repr(acc), hex(bits(acc)))
print("f64->i64           ", int(123456789012.75 * 2.0))
print("i64->f64 987654321 ", hex(bits(987654321.0)))
print("i64->f64 sa        ", hex(bits(float(sa))))
u = 4000000000
print("u32 wrap, div, mod ", (u + u) % 2**32, u // 7, u % 7)
print("u64 rotate         ", hex(((a >> 36) | (a << 28)) & M))
