#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Every register constant of the i.MX RT Adder code against NXP's device header.

    python3 -I tests/imxrt/check_regs.py HEADER_DIR [--compare RT1176_DIR]

HEADER_DIR holds MIMXRT1062.h and fsl_clock.h (third_party/nxp-mcux-rt1062).
Every global of the form `NAME: uintNN = value` with an upper-case NAME in
soc/imxrt/*.ad, soc/imxrt1062/*.ad and boards/teensy41/board.ad must be one of
    <PERIPH>_BASE        == the header's <PERIPH>_BASE
    <PERIPH>_IRQ         == IRQn_Type <PERIPH>_IRQn
    <IP>_<REG>           == offsetof(<IP>_Type, <REG>)   (computed from the struct)
    <IP>_<REG>_<FIELD>   == <IP>_<REG>_<FIELD>_MASK
    <..>_SHIFT           == the header's macro of the same name
    CCM_GATE_* # kCLOCK_X == fsl_clock.h's clock_ip_name_t encoding of kCLOCK_X
or carry `# unchecked: <reason>` (architecture registers, driver policy,
reference-manual facts not in the header).  A constant that is neither is a
failure, as is any mismatch.
--compare: the constants of soc/imxrt/ (the IP blocks the RT1062 and RT1170
share) are also looked up in the RT1176 header; differences are listed (not
failures: they are what a BOARD=hackpad port must change).
Also printed: NXP's documented values of the mux fields the clock report
decodes, next to the decoding in soc/imxrt1062/soc.ad.
"""
import os, re, sys, glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devheader  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
fails = 0
def ok(m): print('[regs] ok: ' + m)
def bad(m):
    global fails
    fails += 1
    print('[regs] FAIL: ' + m)

CONST = re.compile(r'^([A-Z][A-Z0-9_]*)\s*:\s*(?:uint64|uint32|int32|uint16|uint8)\s*=\s*(-?0x[0-9A-Fa-f]+|-?\d+)\s*(#.*)?$')

def constants(path):
    out = []
    for i, line in enumerate(open(path), 1):
        m = CONST.match(line.rstrip())
        if m:
            out.append((m.group(1), int(m.group(2), 0), (m.group(3) or ''), i))
    return out

def resolve(h, gates, name, val, comment):
    """-> (kind, expected) or None if the header does not know the name."""
    if name.startswith('CCM_GATE_'):
        g = re.search(r'#\s*(kCLOCK_\w+)', comment)
        if not g or g.group(1) not in gates:
            return ('gate', None)
        ccgr, shift = gates[g.group(1)]
        return ('gate ' + g.group(1), (ccgr << 8) | shift)
    if name.endswith('_BASE') and name in h.macros:
        return ('base', h.macros[name])
    if name.endswith('_IRQ') and name + 'n' in h.irqs:
        return ('irq', h.irqs[name + 'n'])
    if name.endswith('_SHIFT') and name in h.macros:
        return ('shift', h.macros[name])
    if name + '_MASK' in h.macros:
        return ('mask', h.macros[name + '_MASK'])
    for s in sorted(h.structs, key=len, reverse=True):
        if name.startswith(s + '_') and name[len(s) + 1:] in h.structs[s]:
            return ('offset %s_Type.%s' % (s, name[len(s) + 1:]), h.structs[s][name[len(s) + 1:]][0])
    return None

def main(argv):
    hdir = argv[1]
    cmp_dir = argv[argv.index('--compare') + 1] if '--compare' in argv else None
    h = devheader.DeviceHeader(os.path.join(hdir, 'MIMXRT1062.h'))
    gates = devheader.clock_gates(os.path.join(hdir, 'fsl_clock.h'))
    if h.offset_comment_mismatches:
        bad('the header\'s own offset comments disagree with its structs: %s' % h.offset_comment_mismatches[:5])
    else:
        ok('MIMXRT1062.h: %d structs parsed, every member offset agrees with NXP\'s "offset:" comment' % len(h.structs))
    files = sorted(glob.glob(os.path.join(ROOT, 'soc/imxrt/*.ad')) + glob.glob(os.path.join(ROOT, 'soc/imxrt1062/*.ad')) + [os.path.join(ROOT, 'boards/teensy41/board.ad')])
    counts = {}
    unchecked = []
    for f in files:
        rel = os.path.relpath(f, ROOT)
        for name, val, comment, line in constants(f):
            if comment.startswith('# pad:'):
                counts['pad (check_pins.py)'] = counts.get('pad (check_pins.py)', 0) + 1
                continue
            if '# unchecked:' in comment:
                reason = comment.split('# unchecked:', 1)[1].strip()
                if not reason:
                    bad('%s:%d %s: "unchecked" without a reason' % (rel, line, name))
                unchecked.append((rel, name, reason))
                continue
            r = resolve(h, gates, name, val, comment)
            if r is None:
                bad('%s:%d %s = 0x%X: not in MIMXRT1062.h (and not marked unchecked)' % (rel, line, name, val))
                continue
            kind, exp = r
            if exp is None:
                bad('%s:%d %s: gate comment names no kCLOCK_ of fsl_clock.h' % (rel, line, name))
            elif (val & 0xFFFFFFFF) != (exp & 0xFFFFFFFF):
                bad('%s:%d %s = 0x%X, but the header says 0x%X (%s)' % (rel, line, name, val, exp, kind))
            else:
                k = kind.split()[0]
                counts[k] = counts.get(k, 0) + 1
    ok('constants matching the header: ' + ', '.join('%d %s' % (v, k) for k, v in sorted(counts.items())))
    ok('%d constants marked unchecked, each with a reason (listed in the log)' % len(unchecked))
    for rel, name, reason in unchecked:
        print('    unchecked  %-34s %-28s %s' % (name, rel, reason))
    nvec = h.macros.get('NUMBER_OF_INT_VECTORS')
    soc = open(os.path.join(ROOT, 'soc/imxrt1062/soc.ad')).read()
    m = re.search(r'IMXRT1062_IRQS: uint32 = (\d+)', soc)
    if m and nvec and int(m.group(1)) == nvec - 16:
        ok('IMXRT1062_IRQS %s = NUMBER_OF_INT_VECTORS %d - 16' % (m.group(1), nvec))
    else:
        bad('IMXRT1062_IRQS does not match NUMBER_OF_INT_VECTORS')
    vec = open(os.path.join(ROOT, 'boards/teensy41/vectors.S')).read()
    reps = [int(x) for x in re.findall(r'\.rept\s+(\d+)', vec)]
    if nvec and sum(reps) + 1 == nvec - 16:
        ok('vectors.S has %d interrupt entries (%s + 1)' % (nvec - 16, ' + '.join(map(str, reps))))
    else:
        bad('vectors.S interrupt entries %s + 1 != %d' % (reps, nvec - 16))
    print('[regs] NXP\'s documented values of the mux fields soc/imxrt1062/soc.ad decodes:')
    for f in ['CCM_CBCDR_PERIPH_CLK_SEL', 'CCM_CBCMR_PRE_PERIPH_CLK_SEL', 'CCM_CBCMR_PERIPH_CLK2_SEL', 'CCM_CSCMR1_PERCLK_CLK_SEL', 'CCM_CSCDR1_UART_CLK_SEL', 'CCM_CSCDR2_LPI2C_CLK_SEL', 'CCM_CBCMR_LPSPI_CLK_SEL', 'CCM_CSCMR1_USDHC1_CLK_SEL', 'CCM_CSCMR1_FLEXSPI_CLK_SEL']:
        doc = devheader.field_doc(h, f)
        print('    %-30s %s' % (f, '; '.join('%d: %s' % (k, v.replace('derive clock from ', '')) for k, v in sorted(doc.items()))))
    if cmp_dir:
        h2 = devheader.DeviceHeader(os.path.join(cmp_dir, 'MIMXRT1176_cm7.h'))
        same, diff, missing = 0, [], []
        for f in sorted(glob.glob(os.path.join(ROOT, 'soc/imxrt/*.ad'))):
            for name, val, comment, line in constants(f):
                if '# unchecked:' in comment:
                    continue
                r = resolve(h2, {}, name, val, comment)
                if r is None:
                    missing.append(name)
                elif (r[1] & 0xFFFFFFFF) == (val & 0xFFFFFFFF):
                    same += 1
                else:
                    diff.append('%s: RT1062 0x%X, RT1176 0x%X' % (name, val, r[1]))
        print('[regs] RT1176 (MIMXRT1176_cm7.h) against the shared IP drivers (soc/imxrt/): %d identical, %d different, %d not found' % (same, len(diff), len(missing)))
        for d in diff:
            print('    differs    ' + d)
        for n_ in missing:
            print('    not found  ' + n_)
        for ip in ('LPUART', 'LPI2C', 'LPSPI', 'GPIO', 'USDHC'):
            a, b = h.structs.get(ip, {}), h2.structs.get(ip, {})
            extra = sorted(set(b) - set(a)); gone = sorted(set(a) - set(b))
            moved = sorted(k for k in set(a) & set(b) if a[k][0] != b[k][0])
            print('    %-6s registers: RT1176 adds %s; lacks %s; moved %s' % (ip, extra or '-', gone or '-', moved or '-'))
    print('[regs] %d failures' % fails)
    return fails

if __name__ == '__main__':
    sys.exit(main(sys.argv))
