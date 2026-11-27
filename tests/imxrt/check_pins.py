#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Pin multiplexing and pad settings of the Teensy 4.1 board against NXP and PJRC.

    python3 -I tests/imxrt/check_pins.py NXP_DIR [PJRC_CORE_PINS_H]

  * every iomuxc_pin(...) call in boards/teensy41/board.ad names an
    fsl_iomuxc.h macro in its comment, and its five numbers are that macro's;
  * the pad of that macro is the pad PJRC's Teensy 4.1 pin table gives for
    the Teensy pin named in the comment (tests/imxrt/teensy41_pins.txt; with
    PJRC_CORE_PINS_H the table itself is re-extracted and compared), or the
    SD socket's pad for that signal;
  * I2C pads have SION set (the input path must stay connected);
  * every `# pad:` constant equals the fields it names, composed from
    MIMXRT1062.h's IOMUXC_SW_PAD_CTL_PAD_*_MASK;
  * the early LED and FlexRAM code in vectors.S uses the addresses and
    values of the header and of IOMUXC_GPIO_B0_03_GPIO2_IO03 / kCLOCK_Gpio2;
  * the LED bit is PJRC's CORE_PIN13_BIT on the slow alias of its port.
Exit status = number of failures.
"""
import os, re, sys, subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devheader  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
fails = 0
def ok(m): print('[pins] ok: ' + m)
def bad(m):
    global fails
    fails += 1
    print('[pins] FAIL: ' + m)

PAD_RE = re.compile(r'(GPIO_(?:AD_B0|AD_B1|B0|B1|EMC|SD_B0|SD_B1)_\d\d)')

def main(argv):
    nxp = argv[1]
    pjrc = argv[2] if len(argv) > 2 else None
    io = devheader.iomuxc_macros(os.path.join(nxp, 'fsl_iomuxc.h'))
    h = devheader.DeviceHeader(os.path.join(nxp, 'MIMXRT1062.h'))
    gates = devheader.clock_gates(os.path.join(nxp, 'fsl_clock.h'))
    pins, sd = {}, {}
    for line in open(os.path.join(HERE, 'teensy41_pins.txt')):
        p = line.split()
        if p and p[0] == 'pin':
            pins[int(p[1])] = (p[2], p[3], int(p[4]))
        elif p and p[0] == 'sd':
            sd[p[1]] = p[2]
    if pjrc:
        out = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'extract_t41_pins.py'), pjrc], capture_output=True, text=True, check=True).stdout
        committed = open(os.path.join(HERE, 'teensy41_pins.txt')).read()
        (ok if out == committed else bad)('tests/imxrt/teensy41_pins.txt is what extract_t41_pins.py gets from PJRC\'s core_pins.h (%d pins)' % len(pins))
    else:
        print('[pins] note: PJRC core_pins.h not given; the committed pin table is used as it is')
    board = open(os.path.join(ROOT, 'boards/teensy41/board.ad')).read()
    # pad constants
    masks = dict((k[len('IOMUXC_SW_PAD_CTL_PAD_'):-len('_MASK')], v) for k, v in h.macros.items()
                 if k.startswith('IOMUXC_SW_PAD_CTL_PAD_') and k.endswith('_MASK'))
    padval = {}
    for m in re.finditer(r'^(PAD_\w+): uint32 = (0x[0-9A-Fa-f]+)\s+# pad: ([^;(\n]*)', board, re.M):
        name, val, spec = m.group(1), int(m.group(2), 16), m.group(3).split()
        v = 0
        for f in spec:
            fn, _, fv = f.partition('=')
            mk = masks[fn]
            sh = (mk & -mk).bit_length() - 1
            fv = int(fv) if fv else 1
            if (fv << sh) & ~mk:
                bad('%s: %s=%d does not fit the field' % (name, fn, fv))
            v |= fv << sh
        padval[name] = val
        (ok if v == val else bad)('%s = 0x%05X %s from the header\'s pad-control fields (%s)%s' % (name, val, '==' if v == val else '!=', ' '.join(spec), '' if v == val else ', computed 0x%05X' % v))
    # pin mux calls
    calls = re.findall(r'iomuxc_pin\(([^)]*)\)\s*#\s*(IOMUXC_\w+)(?:, Teensy pin (\d+))?', board)
    n_sd = 0
    for args, macro, tpin in calls:
        a = [x.strip() for x in args.split(',')]
        nums = tuple(int(x, 0) for x in a[:5])
        if macro not in io:
            bad('%s: no such macro in fsl_iomuxc.h' % macro)
            continue
        (ok if nums == io[macro] else bad)('%s: (%s) %s fsl_iomuxc.h' % (macro, ', '.join('0x%X' % x for x in nums), '==' if nums == io[macro] else '!= (0x%X...)' % io[macro][0]))
        pad = PAD_RE.search(macro).group(1)
        if tpin:
            want = pins.get(int(tpin), ('?',))[0]
            (ok if want == pad else bad)('  Teensy pin %s is pad %s (PJRC: %s)' % (tpin, pad, want))
        elif 'USDHC1' in macro:
            sig = 'SD_' + macro.rsplit('_', 1)[1].replace('DATA', 'DAT')
            (ok if sd.get(sig) == pad else bad)('  %s is pad %s (SdFat\'s Teensy 4.1 SD socket: %s)' % (sig, pad, sd.get(sig)))
            n_sd += 1
        else:
            bad('%s: the comment names no Teensy pin' % macro)
        if 'LPI2C' in macro:
            (ok if a[6] == '1' else bad)('  %s with SION set' % macro)
        if a[5] not in padval:
            bad('  %s: pad control %s is not a checked PAD_ constant' % (macro, a[5]))
    (ok if n_sd == 6 else bad)('all six SD socket signals are muxed (%d)' % n_sd)
    # vectors.S early code
    vs = open(os.path.join(ROOT, 'boards/teensy41/vectors.S')).read()
    led = io['IOMUXC_GPIO_B0_03_GPIO2_IO03']
    want = {
        'IOMUXC_GPR': h.macros['IOMUXC_GPR_BASE'],
        'CCM_CCGR0': h.macros['CCM_BASE'] + h.structs['CCM']['CCGR0'][0],
        'SW_MUX_CTL_PAD_GPIO_B0_03': led[0],
        'SW_PAD_CTL_PAD_GPIO_B0_03': led[4],
        'GPIO2': h.macros['GPIO2_BASE'],
    }
    for name, addr in want.items():
        m = re.search(r'ldr\s+r0, =(0x[0-9A-Fa-f]+)\s+/\* ' + name + r'\b', vs)
        (ok if m and int(m.group(1), 16) == addr else bad)('vectors.S: %s at 0x%08X' % (name, addr))
    offs = dict((n, h.structs['IOMUXC_GPR'][n][0]) for n in ('GPR14', 'GPR16', 'GPR17'))
    g17 = re.search(r'str\s+r1, \[r0, #(0x[0-9A-Fa-f]+)\]\s+/\* GPR17', vs)
    (ok if g17 and int(g17.group(1), 16) == offs['GPR17'] else bad)('vectors.S: GPR17 at IOMUXC_GPR + 0x%X' % offs['GPR17'])
    g16 = re.findall(r'\[r0, #(0x[0-9A-Fa-f]+)\]', vs[vs.index('/* GPR17 */'):vs.index('GPR16: BANK_CFG_SEL') + 200])
    (ok if g16 and int(g16[0], 16) == offs['GPR16'] else bad)('vectors.S: GPR16 at IOMUXC_GPR + 0x%X' % offs['GPR16'])
    g14 = re.findall(r'\[r0, #(0x[0-9A-Fa-f]+)\]', vs[vs.index('GPR16: BANK_CFG_SEL'):vs.index('GPR14: ITCM and DTCM')])
    (ok if g14 and int(g14[-1], 16) == offs['GPR14'] else bad)('vectors.S: GPR14 at IOMUXC_GPR + 0x%X' % offs['GPR14'])
    sel = h.macros['IOMUXC_GPR_GPR16_FLEXRAM_BANK_CFG_SEL_MASK']
    print('[pins] note: GPR16 |= 7 sets FLEXRAM_BANK_CFG_SEL (0x%X, in the header) and bits 0-1, INIT_ITCM_EN/INIT_DTCM_EN in the RM and PJRC\'s start-up, not named in MIMXRT1062.h; GPR14 bits 23:16 likewise RM-only' % sel)
    m = re.search(r'movs\s+r1, #(\d+)\s+/\* ALT5', vs)
    (ok if m and int(m.group(1)) == led[1] else bad)('vectors.S: LED pad mux mode %d (IOMUXC_GPIO_B0_03_GPIO2_IO03)' % led[1])
    ccgr, sh = gates['kCLOCK_Gpio2']
    m = re.search(r'orr\s+r1, r1, #(0x[0-9A-Fa-f]+)\s+/\* CG15: GPIO2', vs)
    (ok if m and ccgr == 0 and int(m.group(1), 16) == 3 << sh else bad)('vectors.S: GPIO2 clock gate CCGR%d bits %d-%d (kCLOCK_Gpio2)' % (ccgr, sh, sh + 1))
    m = re.search(r'^LED_BIT: uint32 = (\d+)', board, re.M)
    pad13, port13, bit13 = pins[13]
    (ok if m and int(m.group(1)) == bit13 and pad13 == PAD_RE.search('IOMUXC_GPIO_B0_03_GPIO2_IO03').group(1) and port13 == 'GPIO7' else bad)(
        'LED: pin 13 is %s, bit %d of %s (fast alias of GPIO2), and the board drives GPIO2 bit %s' % (pad13, bit13, port13, m.group(1) if m else '?'))
    m = re.search(r'movs\s+r1, #(0x[0-9A-Fa-f]+)\s+/\* DSE = 7', vs)
    (ok if m and int(m.group(1), 16) == padval.get('PAD_LED') else bad)('vectors.S: LED pad control 0x%s = PAD_LED' % (m.group(1)[2:] if m else '?'))
    print('[pins] %d failures' % fails)
    return fails

if __name__ == '__main__':
    sys.exit(main(sys.argv))
