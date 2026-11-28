#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# check_regs.py MDK_DIR ADFILE...
#
# Every upper-case module constant `NAME: type = VALUE  # ...` of the given
# Adder files must carry either
#     hdr: SYMBOL       compared with Nordic's nrf52840.h / _bitfields.h:
#                       SYMBOL is a #define (evaluated), an IRQn enumerator,
#                       or TYPE.member[.member][[index]] -- a register
#                       offset, computed from the header's struct layout
#     unchecked: WHY    a fact the device header does not hold
# The struct layouts are computed from the member declarations (uint32_t,
# uint8_t, nested *_Type structs, arrays, RESERVED padding) and checked
# against the header's own "Size = N" comment of every struct used, so a
# parsing mistake shows up as a size mismatch rather than a wrong pass.
# Reads the headers as text (python3 -I; nothing is compiled).
import ast, os, re, sys

mdk = sys.argv[1]
H = open(os.path.join(mdk, 'nrf52840.h')).read()
BF = open(os.path.join(mdk, 'nrf52840_bitfields.h')).read()
fails = 0
nchecked = {'define': 0, 'irq': 0, 'offset': 0}


def fail(msg):
    global fails
    fails += 1
    print("check_regs: FAIL:", msg)


# ---- #defines -------------------------------------------------------------
defs = {}
for m in re.finditer(r'^#define\s+(\w+)\s+(.+?)\s*(?:/\*.*)?$', H + '\n' + BF, re.M):
    defs.setdefault(m.group(1), m.group(2))


def ev(expr, depth=0):
    if depth > 20:
        raise ValueError('recursion')
    e = re.sub(r'\b(0x[0-9A-Fa-f]+|\d+)[uUlL]+\b', r'\1', expr)
    e = re.sub(r'\(\s*\(?\s*uint32_t\s*\)?\s*\)', '', e)
    def sub(m):
        n = m.group(0)
        if n in defs:
            return '(' + str(ev(defs[n], depth + 1)) + ')'
        raise KeyError(n)
    e = re.sub(r'\b[A-Za-z_]\w*\b', sub, e)
    tree = ast.parse(e, mode='eval')
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant, ast.LShift, ast.RShift,
                                 ast.BitOr, ast.BitAnd, ast.BitXor, ast.Add, ast.Sub, ast.Mult, ast.Invert, ast.USub)):
            raise ValueError('not arithmetic: ' + expr)
    return eval(compile(tree, '<hdr>', 'eval')) & 0xFFFFFFFF

# ---- IRQn ------------------------------------------------------------------
irqs = {m.group(1): int(m.group(2)) for m in re.finditer(r'^\s*(\w+_IRQn)\s*=\s*(-?\d+)', H, re.M)}

# ---- structs ---------------------------------------------------------------
structs = {}       # name -> (members: [(name, offset, elemsize, count)], size, declared size)
SIZES = {'uint32_t': 4, 'uint16_t': 2, 'uint8_t': 1, 'int32_t': 4}
for m in re.finditer(r'typedef struct \{[^\n]*\n(.*?)\n\} (\w+);\s*/\*!< Size = (\d+)', H, re.S):
    body, name, declared = m.group(1), m.group(2), int(m.group(3))
    off = 0
    mem = []
    ok = True
    body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)      # comments may span lines
    for line in body.split('\n'):
        line = line.strip()
        if not line:
            continue
        d = re.match(r'(?:__IOM|__IM|__OM)?\s*(?:const\s+)?(\w+)\s+(\w+)(?:\[(\d+)\])?\s*;$', line)
        if not d:
            ok = False
            break
        typ, mname, cnt = d.group(1), d.group(2), int(d.group(3) or 1)
        if typ in SIZES:
            es = SIZES[typ]
        elif typ in structs:
            es = structs[typ][1]
        else:
            ok = False
            break
        al = min(es, 4)
        off = (off + al - 1) // al * al
        mem.append((mname, off, es, cnt, typ))
        off += es * cnt
    if ok:
        structs[name] = (mem, off, declared)


def offset(path, line):
    # TYPE.a.b[3] -> byte offset
    typ, *parts = path.split('.')
    if typ not in structs:
        raise KeyError('struct ' + typ)
    total = 0
    for p in parts:
        mm = re.match(r'(\w+)(?:\[(\d+)\])?$', p)
        mname, idx = mm.group(1), int(mm.group(2) or 0)
        mem, size, declared = structs[typ]
        if size != declared:
            fail(f"{typ}: computed size {size} != the header's Size = {declared}")
        for (n, o, es, cnt, t) in mem:
            if n == mname:
                if idx >= cnt:
                    raise KeyError(f'{p}: index beyond {cnt}')
                total += o + idx * es
                typ = t
                break
        else:
            raise KeyError(f'{typ} has no member {mname}')
    return total


const_re = re.compile(r'^([A-Z][A-Z0-9_]*)\s*:\s*\w+\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*(#.*)?$')
total = unchecked = 0
for f in sys.argv[2:]:
    for n, line in enumerate(open(f), 1):
        m = const_re.match(line.strip())
        if not m:
            continue
        total += 1
        name, val, com = m.group(1), int(m.group(2), 0), (m.group(3) or '')
        where = f"{f}:{n} {name}"
        if 'unchecked:' in com:
            unchecked += 1
            continue
        h = re.search(r'hdr:\s*(\S+)', com)
        if not h:
            fail(f"{where}: neither 'hdr:' nor 'unchecked:'")
            continue
        sym = h.group(1)
        try:
            if '.' in sym:
                want = offset(sym, line)
                kind = 'offset'
            elif sym in irqs:
                want = irqs[sym]
                kind = 'irq'
            else:
                want = ev(defs[sym]) if sym in defs else None
                if want is None:
                    raise KeyError(sym)
                kind = 'define'
        except (KeyError, ValueError) as e:
            fail(f"{where}: {sym}: not found in the header ({e})")
            continue
        if want != val:
            fail(f"{where} = 0x{val:X}, header {sym} = 0x{want:X}")
        else:
            nchecked[kind] += 1
print(f"check_regs: {total} constants: {nchecked['define']} defines (addresses, bit positions, masks, values), "
      f"{nchecked['irq']} interrupt numbers, {nchecked['offset']} register offsets match; {unchecked} marked unchecked; {fails} failures")
# The vector table: 16 + (highest IRQn + 1) entries.
nirq = max(v for v in irqs.values()) + 1
vs = open('boards/feather_nrf52840/vectors.S').read()
body = vs[vs.index('hmicro_vectors:'):vs.index('.size hmicro_vectors')]
words = len(re.findall(r'^\s*\.word\s+\w+\s*(?:/\*.*)?$', body, re.M)) + 4 * len(re.findall(r'\.word\s+0, 0, 0, 0', body))
words += sum(int(r) for r in re.findall(r'\.rept\s+(\d+)', body)) - len(re.findall(r'\.rept', body))
if words != 16 + nirq:
    fail(f"vector table has {words} entries, the header's interrupts need 16 + {nirq}")
else:
    print(f"check_regs: vector table: 16 + {nirq} entries, as the header's last IRQn ({nirq - 1}) needs")
for irq, label in ((irqs['UART0_UARTE0_IRQn'], 'uart0_rx_handler'), (irqs['RTC1_IRQn'], 'board_rtc1_handler')):
    if not re.search(rf'\.word\s+{label}\s+/\* IRQ {irq}:', vs):
        fail(f"vector table: IRQ {irq} is not {label}")
sys.exit(1 if fails else 0)
