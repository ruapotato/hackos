#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Teensy 4.1 pin table (pin -> pad, GPIO port and bit) from PJRC's core_pins.h.

    python3 -I tests/imxrt/extract_t41_pins.py .../teensy4/core_pins.h > tests/imxrt/teensy41_pins.txt

Reads the `#elif defined(__IMXRT1062__) && defined(ARDUINO_TEENSY41)` section
as text (CORE_PINn_CONFIG = IOMUXC_SW_MUX_CTL_PAD_<pad>, CORE_PINn_BIT,
CORE_PINn_PORTREG) and prints one line per pin.  The output is a table of
facts in HackOS's own format; check_pins.py compares the board's pin mux
against it, and against core_pins.h again when that file is given.
"""
import re, sys

def table(path):
    t = open(path, encoding='latin-1').read()
    i = t.index('#elif defined(__IMXRT1062__) && defined(ARDUINO_TEENSY41)')
    j = t.find('\n#elif ', i + 10)
    k = t.find('\n#endif', i + 10)
    sec = t[i:min(x for x in (j, k) if x > 0)]
    pads = dict((int(n), p) for n, p in re.findall(r'#define CORE_PIN(\d+)_CONFIG\s+IOMUXC_SW_MUX_CTL_PAD_(\w+)', sec))
    bits = dict((int(n), int(b)) for n, b in re.findall(r'#define CORE_PIN(\d+)_BIT\s+(\d+)', sec))
    ports = dict((int(n), p) for n, p in re.findall(r'#define CORE_PIN(\d+)_PORTREG\s+(GPIO\d+)_DR', sec))
    return [(n, pads[n], ports.get(n, '?'), bits.get(n, -1)) for n in sorted(pads)]

if __name__ == '__main__':
    print('# Teensy 4.1 pin -> i.MX RT1062 pad, fast-GPIO port, bit.  Extracted by')
    print('# tests/imxrt/extract_t41_pins.py from PJRC teensy4/core_pins.h (cores commit')
    print('# 27adf000f85619481a47233bb977b64ac41f71d8, sha256')
    print('# c7f002d6763f05fd0ec68ebb879220baee79b48f6a22dd45de0ce88ae0e0e5bc).')
    print('# GPIO6..9 are the fast aliases of GPIO1..4 (IOMUXC_GPR_GPR26..29 select).')
    print('# The SD socket is not a numbered pin: its pads are GPIO_SD_B0_00..05 (CMD,')
    print('# CLK, DAT0..DAT3), from SdFat src/SdCard/TeensySdio/TeensySdio.cpp gpioMux().')
    for n, pad, port, bit in table(sys.argv[1]):
        print('pin %d %s %s %d' % (n, pad, port, bit))
    for name, pad in (('SD_CMD', 'GPIO_SD_B0_00'), ('SD_CLK', 'GPIO_SD_B0_01'), ('SD_DAT0', 'GPIO_SD_B0_02'), ('SD_DAT1', 'GPIO_SD_B0_03'), ('SD_DAT2', 'GPIO_SD_B0_04'), ('SD_DAT3', 'GPIO_SD_B0_05')):
        print('sd %s %s' % (name, pad))
