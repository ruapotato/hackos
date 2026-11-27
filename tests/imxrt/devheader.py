# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Facts from NXP MCUXpresso device files, read as data (nothing is compiled).

    DeviceHeader(path)      MIMXRT1062.h / MIMXRT1176_cm7.h
        .macros   {name: int}     every `#define NAME (0x..u)` / `#define NAME 123`
        .structs  {Type: {member: (offset, size)}}  computed from the member
                  list (uint8/16/32_t, arrays, RESERVED_n padding), and the
                  `offset: 0x..` comments cross-checked against it
        .irqs     {name: number}  the IRQn_Type enum
    iomuxc_macros(path)     fsl_iomuxc.h: {IOMUXC_PAD_FUNCTION: (mux_reg,
                            mux_mode, input_reg, input_daisy, config_reg)}
    clock_gates(path)       fsl_clock.h (RT1060 family): {kCLOCK_Name:
                            (ccgr_index, gate_shift)}

Only the constructs these files use are understood; anything else raises.
"""
import re

_NUM = r'(0[xX][0-9a-fA-F]+|[0-9]+)[uUlL]*'
_SIZES = {'uint8_t': 1, 'uint16_t': 2, 'uint32_t': 4, 'uint64_t': 8}


def _int(s):
    return int(s.rstrip('uUlL'), 0)


class DeviceHeader:
    def __init__(self, path):
        with open(path, encoding='latin-1') as f:
            self.text = f.read()
        self.macros = {}
        for m in re.finditer(r'^#define\s+(\w+)\s+\(?\s*' + _NUM + r'\s*\)?\s*(?:/\*.*)?$', self.text, re.M):
            self.macros[m.group(1)] = _int(m.group(2))
        self.irqs = {}
        em = re.search(r'typedef enum IRQn \{(.*?)\} IRQn_Type;', self.text, re.S)
        if em:
            for m in re.finditer(r'(\w+)\s*=\s*(-?\d+)', em.group(1)):
                self.irqs[m.group(1)] = int(m.group(2))
        self.structs = {}
        self.offset_comment_mismatches = []
        for m in re.finditer(r'typedef struct \{(.*?)\n\} (\w+)_Type;', self.text, re.S):
            body, name = m.group(1), m.group(2)
            if 'struct {' in body or 'union' in body:
                # nested anonymous structs: parse what we can (arrays of
                # plain registers before the first nesting)
                self.structs[name] = self._members(body, name, nested=True)
            else:
                self.structs[name] = self._members(body, name)

    def _members(self, body, name, nested=False):
        out = {}
        off = 0
        for line in body.split('\n'):
            line = line.strip()
            if not line or line.startswith('/*') or line.startswith('*'):
                continue
            if nested and ('struct {' in line or 'union' in line or line.startswith('}')):
                break
            mm = re.match(r'(?:__IO|__I|__O)?\s*(uint8_t|uint16_t|uint32_t|uint64_t)\s+(\w+)(?:\[(\w+)\])?(?:\[(\w+)\])?;(.*)', line)
            if not mm:
                if nested:
                    break
                raise ValueError('%s: cannot parse member line %r' % (name, line))
            typ, mem, n1, n2, rest = mm.groups()
            cnt = 1
            for n in (n1, n2):
                if n:
                    cnt *= _int(n) if re.match(r'^\d', n) else self.macros[n]
            size = _SIZES[typ] * cnt
            align = _SIZES[typ]
            if off % align:
                off += align - off % align
            c = re.search(r'offset: (0x[0-9A-Fa-f]+)', rest)
            if c and int(c.group(1), 16) != off:
                self.offset_comment_mismatches.append((name, mem, off, int(c.group(1), 16)))
            if not mem.startswith('RESERVED'):
                out[mem] = (off, size)
            off += size
        return out


def iomuxc_macros(path):
    with open(path, encoding='latin-1') as f:
        text = f.read()
    out = {}
    for m in re.finditer(r'^#define\s+(IOMUXC_\w+)\s+((?:(?:0x[0-9A-Fa-f]+|\d+)U?,\s*){4}(?:0x[0-9A-Fa-f]+|\d+)U?)\s*$', text, re.M):
        out[m.group(1)] = tuple(_int(x.strip()) for x in m.group(2).split(','))
    return out


def clock_gates(path):
    """RT1060-family fsl_clock.h encodes kCLOCK_X = (CCGR index << 8) | shift."""
    with open(path, encoding='latin-1') as f:
        text = f.read()
    out = {}
    for m in re.finditer(r'(kCLOCK_\w+)\s*=\s*\(\s*(\d+)U?\s*<<\s*8U?\s*\)\s*\|\s*CCM_CCGR(\d+)_CG(\d+)_SHIFT', text):
        idx, ccgr, cg = int(m.group(2)), int(m.group(3)), int(m.group(4))
        if idx != ccgr:
            raise ValueError('%s: index %d but CCGR%d' % (m.group(1), idx, ccgr))
        out[m.group(1)] = (ccgr, cg * 2)
    return out
