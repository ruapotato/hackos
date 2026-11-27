#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""Check the Teensy 4.1 image's boot header against NXP's documented structures.

    python3 -I tests/imxrt/check_boot.py ELF BIN HEX NXP_DIR [PJRC_BOOTDATA_C]

NXP_DIR is third_party/nxp-mcux-rt1062 (the structure definitions are read
from its evkmimxrt1060_flexspi_nor_config.h and fsl_flexspi_nor_boot.h, the
FlexSPI base and vector count from MIMXRT1062.h).  PJRC_BOOTDATA_C, if given,
is PJRC's teensy4/bootdata.c; its Teensy 4.1 FCB is compared word by word
(the file is read as text, never compiled).

What is checked:
  * the C structure layouts parse and their computed offsets agree with the
    offsets NXP wrote in the comments ([0x044-0x044] ...);
  * FCB (flexspi_nor_config_t at 0x60000000): tag, version, the fields the
    ROM needs for a quad SPI NOR, the read LUT sequence decoded instruction by
    instruction against the opcode table in the header, flash size 8 MiB,
    page/sector/block sizes of the W25Q64JV;
  * IVT (ivt at 0x60001000): header tag/length/version, entry = the ELF's
    Reset_Handler with the Thumb bit and inside the image, self, boot data
    pointer, no DCD, no CSF;
  * boot data (BOOT_DATA_T): start = FlexSPI_AMBA_BASE, size covers the
    whole image, not a plugin;
  * the vector table: VTOR alignment for NUMBER_OF_INT_VECTORS entries,
    initial SP in DTCM, every handler a Thumb address inside the image, the
    console's interrupt (LPUART6_IRQn) wired to the console handler;
  * the HEX file holds exactly the bytes of the binary, all inside the
    7936 KB the Teensy loader accepts;
  * every loadable ELF segment's load address is in flash;
  * the FlexRAM bank word matches the linker's ITCM/DTCM/OCRAM sizes.
Prints "ok:"/"FAIL:" lines; exit status = number of failures.
"""
import os, re, struct, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devheader  # noqa: E402

fails = 0
def ok(msg): print('[boot] ok: ' + msg)
def bad(msg):
    global fails
    fails += 1
    print('[boot] FAIL: ' + msg)
def check(cond, msg, why=''):
    (ok if cond else bad)(msg + ('' if cond or not why else ' (' + why + ')'))

SIZES = {'uint8_t': 1, 'uint16_t': 2, 'uint32_t': 4}

def parse_structs(text):
    """typedef struct NAME { members } TYPE;  ->  {TYPE: (size, [(name, off, size, count, elemtype)])}"""
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    types = dict((k, (v, v)) for k, v in SIZES.items())   # name -> (size, align)
    out = {}
    for m in re.finditer(r'typedef struct\s*\w*\s*\{(.*?)\}\s*(\w+)\s*;', text, re.S):
        body, tname = m.group(1), m.group(2)
        off, align_max, members = 0, 1, []
        for decl in body.split(';'):
            decl = ' '.join(decl.split())
            if not decl:
                continue
            dm = re.match(r'(\w+) (\w+)(?:\[(\d+)\])?$', decl)
            if not dm:
                raise ValueError('%s: cannot parse %r' % (tname, decl))
            ty, name, cnt = dm.group(1), dm.group(2), int(dm.group(3) or 1)
            size, align = types[ty]
            off = (off + align - 1) // align * align
            members.append((name, off, size, cnt, ty))
            off += size * cnt
            align_max = max(align_max, align)
        total = (off + align_max - 1) // align_max * align_max
        types[tname] = (total, align_max)
        out[tname] = (total, members)
    return out

def comment_offsets(text, members):
    """NXP's '//!< [0x044-0x044] ...' comments: member name -> first offset."""
    out = {}
    for m in re.finditer(r'(\w+)(?:\[\d+\])?;\s*//!<\s*\[(0x[0-9a-fA-F]+)-', text):
        out[m.group(1)] = int(m.group(2), 16)
    return out

def field(blob, base, members, name, idx=0):
    for (n, off, size, cnt, ty) in members:
        if n == name:
            o = base + off + idx * size
            return int.from_bytes(blob[o:o + size], 'little')
    raise KeyError(name)

def nm(elf):
    syms = {}
    for line in subprocess.run(['llvm-nm', elf], capture_output=True, text=True, check=True).stdout.splitlines():
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16)
    return syms

def ihex(path):
    data, upper = {}, 0
    for ln, line in enumerate(open(path), 1):
        line = line.strip()
        if not line:
            continue
        assert line[0] == ':', 'line %d' % ln
        rec = bytes.fromhex(line[1:])
        n, addr, typ = rec[0], (rec[1] << 8) | rec[2], rec[3]
        if sum(rec) & 0xFF:
            raise ValueError('checksum, line %d' % ln)
        payload = rec[4:4 + n]
        if typ == 0:
            for i, b in enumerate(payload):
                data[upper + addr + i] = b
        elif typ == 4:
            upper = int.from_bytes(payload, 'big') << 16
        elif typ == 2:
            upper = int.from_bytes(payload, 'big') << 4
        elif typ in (1, 3, 5):
            pass
        else:
            raise ValueError('record type %d' % typ)
    return data

def main(argv):
    elf, binf, hexf, nxp = argv[1:5]
    pjrc = argv[5] if len(argv) > 5 else None
    img = open(binf, 'rb').read()
    FLASH = 0x60000000
    syms = nm(elf)
    hdr = devheader.DeviceHeader(os.path.join(nxp, 'MIMXRT1062.h'))
    check(hdr.macros.get('FlexSPI_AMBA_BASE') == FLASH, 'FlexSPI_AMBA_BASE is 0x60000000 (MIMXRT1062.h)')
    check(syms.get('hackos_fcb') == FLASH and img[:4] == struct.pack('<I', 0x42464346), 'the binary starts at 0x60000000 with the FCB')

    # ---- structure definitions
    cfg_text = open(os.path.join(nxp, 'evkmimxrt1060_flexspi_nor_config.h'), encoding='latin-1').read()
    boot_text = open(os.path.join(nxp, 'fsl_flexspi_nor_boot.h'), encoding='latin-1').read()
    structs = parse_structs(cfg_text)
    structs.update(parse_structs(boot_text))
    mem_size, mem = structs['flexspi_mem_config_t']
    nor_size, nor = structs['flexspi_nor_config_t']
    check(mem_size == 448, 'flexspi_mem_config_t parses to 448 bytes', '%d' % mem_size)
    check(nor_size == 512, 'flexspi_nor_config_t parses to 512 bytes', '%d' % nor_size)
    co = comment_offsets(cfg_text, mem)
    mism = [(n, off, co[n]) for (n, off, s, c, t) in mem if n in co and co[n] != off]
    check(len(co) >= 30 and not mism, 'member offsets agree with the [0x...] offsets in NXP\'s comments (%d compared)' % len(co), str(mism))
    ivt_size, ivt = structs['ivt']
    bd_size, bd = structs['BOOT_DATA_T']
    check(ivt_size == 32 and bd_size == 16, 'ivt is 32 bytes and BOOT_DATA_T 16')

    # ---- FCB
    m = cfg_text
    def mac(name):
        mm = re.search(r'#define\s+%s\s+\(?(0x[0-9A-Fa-f]+|\d+)' % name, m)
        return int(mm.group(1), 0)
    def mf(name, idx=0):
        return field(img, 0, mem, name, idx)
    check(mf('tag') == mac('FLEXSPI_CFG_BLK_TAG'), 'FCB tag = FLEXSPI_CFG_BLK_TAG ("FCFB")')
    ver = mf('version')
    check((ver >> 24) == 0x56 and ((ver >> 16) & 0xFF) == 1, 'FCB version is V1.x (0x%08X; NXP\'s current is 0x%08X, PJRC\'s 0x56010000)' % (ver, mac('FLEXSPI_CFG_BLK_VERSION')))
    check(mf('readSampleClkSrc') in (0, 1, 3), 'readSampleClkSrc %d is one of the valid 0/1/3 (1 = loopback from DQS pad)' % mf('readSampleClkSrc'))
    check(1 <= mf('csHoldTime') <= 15 and 1 <= mf('csSetupTime') <= 15, 'CS hold %d / setup %d serial clocks' % (mf('csHoldTime'), mf('csSetupTime')))
    check(mf('deviceType') == 1, 'deviceType 1 = kFlexSpiDeviceType_SerialNOR')
    check(mf('sflashPadType') == 4, 'sflashPadType 4 = quad')
    clk = re.findall(r'kFlexSpiSerialClk_(\d+)MHz\s*=\s*(\d+)', m)
    clkmap = dict((int(v), int(k)) for k, v in clk)
    check(mf('serialClkFreq') in clkmap, 'serialClkFreq %d = %s MHz (NXP\'s enum; W25Q64JV quad I/O reads up to 133 MHz)' % (mf('serialClkFreq'), clkmap.get(mf('serialClkFreq'))))
    check(mf('sflashA1Size') == 8 * 1024 * 1024 and mf('sflashA2Size') == 0 and mf('sflashB1Size') == 0 and mf('sflashB2Size') == 0, 'flash A1 is 8 MiB, no other flash')
    check(mf('deviceModeCfgEnable') == 0 and mf('configCmdEnable') == 0, 'no device-mode or configuration commands (the flash keeps its QE bit)')
    check(mf('controllerMiscOption') == 0, 'controllerMiscOption 0: SDR, single-ended clock, no pad overrides')
    # decode LUT sequence 0 (read)
    ops = dict((int(v, 16), k) for k, v in re.findall(r'#define\s+(\w+(?:_SDR|_DDR|_ON_CS|STOP))\s+(0x[0-9A-Fa-f]+|0)\b', m))
    ops[0] = 'STOP'
    seq = []
    for w in range(4):
        word = mf('lookupTable', w)
        for half in (word & 0xFFFF, word >> 16):
            seq.append((ops.get(half >> 10, '?%d' % (half >> 10)), 1 << ((half >> 8) & 3), half & 0xFF))
    got = []
    for op, pads, operand in seq:
        got.append((op, pads, operand))
        if op == 'STOP':
            break
    want = [('CMD_SDR', 1, 0xEB), ('RADDR_SDR', 4, 24), ('MODE8_SDR', 4, 0xFF), ('DUMMY_SDR', 4, 4), ('READ_SDR', 4, 1), ('STOP', 1, 0)]
    check(got == want, 'read LUT: CMD_SDR 0xEB on 1 pad, RADDR_SDR 24 bits, MODE8_SDR 0xFF, DUMMY_SDR 4, READ_SDR, STOP on 4 pads (W25Q64JV "Fast Read Quad I/O")', str(got))
    check(all(mf('lookupTable', i) == 0 for i in range(4, 64)), 'LUT sequences 1..15 empty (the ROM only reads)')
    def nf(name):
        return field(img, 0, nor, name)
    check(nf('pageSize') == 256 and nf('sectorSize') == 4096 and nf('blockSize') == 65536, 'NOR page 256, sector 4096, block 65536 bytes (W25Q64JV)')
    check(nf('ipcmdSerialClkFreq') in clkmap, 'ipcmdSerialClkFreq %d = %s MHz' % (nf('ipcmdSerialClkFreq'), clkmap.get(nf('ipcmdSerialClkFreq'))))
    if mf('lutCustomSeqEnable') != 0:
        print('[boot] note: lutCustomSeqEnable is 1 with no custom sequences (as in PJRC\'s FCB; NXP documents it as needed only for HyperFLASH)')

    # ---- IVT and boot data
    IVT = 0x1000
    def iv(name):
        return field(img, IVT, ivt, name)
    h = iv('hdr')
    check(h & 0xFF == 0xD1, 'IVT tag 0xD1 (IVT_TAG_HEADER)')
    check(((h >> 8) & 0xFF) << 8 | ((h >> 16) & 0xFF) == 32, 'IVT length 32, big-endian in the header')
    check((h >> 28) == 4, 'IVT version major 4 (0x%02X; NXP 0x41, PJRC 0x43)' % (h >> 24))
    rh = syms['Reset_Handler']
    check(iv('entry') == (rh | 1), 'IVT entry = Reset_Handler 0x%08X with the Thumb bit' % rh)
    end = syms['__flash_end']
    check(FLASH + 0x2000 <= iv('entry') < end, 'IVT entry inside the image')
    check(iv('self') == FLASH + IVT and syms.get('hackos_ivt') == FLASH + IVT, 'IVT self = 0x60001000')
    check(iv('dcd') == 0 and iv('csf') == 0 and iv('reserved1') == 0 and iv('reserved2') == 0, 'no DCD, no CSF, reserved words 0')
    bda = iv('boot_data')
    check(bda == syms.get('hackos_boot_data') and FLASH <= bda < FLASH + 0x2000, 'IVT boot_data points at the boot data (0x%08X)' % bda)
    bo = bda - FLASH
    def bf(name):
        return field(img, bo, bd, name)
    check(bf('start') == FLASH, 'boot data start = 0x60000000')
    check(bf('size') >= end - FLASH and bf('size') <= 7936 * 1024, 'boot data size %d covers the image (%d bytes) and fits 7936 KB' % (bf('size'), end - FLASH))
    check(bf('plugin') == 0, 'boot data: not a plugin')
    check(len(img) == end - FLASH, 'the binary is the whole image (%d bytes)' % len(img))

    # ---- vector table
    nvec = hdr.macros['NUMBER_OF_INT_VECTORS']
    vt = syms['hackos_vectors']
    align = 1
    while align < nvec * 4:
        align *= 2
    check(vt % align == 0, 'vector table at 0x%08X, aligned to %d (VTOR, %d entries)' % (vt, align, nvec))
    vo = vt - FLASH
    vec = struct.unpack('<%dI' % nvec, img[vo:vo + 4 * nvec])
    check(vec[0] == syms['__stack_top'] and 0x20000000 <= vec[0] <= 0x20000000 + 512 * 1024, 'initial SP = __stack_top in DTCM (0x%08X)' % vec[0])
    check(vec[1] == rh | 1, 'reset vector = Reset_Handler')
    badv = [i for i in list(range(1, 7)) + [11, 12, 14, 15] + list(range(16, nvec)) if not (vec[i] & 1 and FLASH <= vec[i] < end)]
    check(not badv, 'all %d handler entries are Thumb addresses inside the image' % (len(range(16, nvec)) + 10), str(badv[:8]))
    irq = hdr.irqs['LPUART6_IRQn']
    check(vec[16 + irq] == syms['uart0_rx_handler'] | 1, 'IRQ %d (LPUART6_IRQn) is the console receive handler' % irq)
    check(vec[15] == syms['systick_handler'] | 1 and vec[14] == syms['pendsv_handler'] | 1 and vec[11] == syms['svc_handler'] | 1, 'SysTick, PendSV and SVCall are the kernel\'s handlers')
    others = set(vec[16 + i] for i in range(nvec - 16) if i != irq)
    check(others == {syms['irq_default_handler'] | 1}, 'every other interrupt goes to irq_default_handler (reported as unexpected)')

    # ---- HEX file
    hx = ihex(hexf)
    lo, hi = min(hx), max(hx) + 1
    check(lo == FLASH and hi <= FLASH + 7936 * 1024, 'HEX covers 0x%08X..0x%08X, inside the loader\'s 7936 KB' % (lo, hi))
    same = all(hx.get(FLASH + i, None) == b for i, b in enumerate(img) if (FLASH + i) in hx) and \
        all(img[a - FLASH] == b for a, b in hx.items())
    check(same, 'HEX bytes equal the binary at the same addresses (%d bytes)' % len(hx))
    holes = [a for a in range(FLASH, FLASH + 0x2000) if a not in hx and img[a - FLASH] != 0xFF]
    check(not holes, 'boot header present in the HEX file')

    # ---- ELF load addresses
    ph = subprocess.run(['llvm-readelf', '-lW', elf], capture_output=True, text=True, check=True).stdout
    loads = [l.split() for l in ph.splitlines() if l.strip().startswith('LOAD')]
    badl = [l for l in loads if int(l[3], 16) and not (FLASH <= int(l[3], 16) < FLASH + 7936 * 1024) and int(l[4], 16) != 0]
    check(loads and not badl, 'every loadable segment with file contents has its load address in flash (%d segments)' % len(loads), str(badl))
    check(FLASH <= syms['__data_load'] < end and 0x20000000 <= syms['__data_start'] < 0x20040000, '.data loads from flash and lives in DTCM')

    # ---- FlexRAM
    cfg = syms['__flexram_bank_config']
    kinds = [(cfg >> (2 * i)) & 3 for i in range(16)]
    n_itcm, n_dtcm, n_ocram = kinds.count(3), kinds.count(2), kinds.count(1)
    check(kinds.count(0) == 0, 'FlexRAM: all 16 banks in use')
    check(n_itcm == 1 and n_dtcm * 32 * 1024 == syms['__ram_end'] - 0x20000000 and 0x20280000 + n_ocram * 32 * 1024 == syms['__prog_end'],
          'FlexRAM word 0x%08X = %d ITCM, %d DTCM, %d OCRAM banks, as the linker script lays out' % (cfg, n_itcm, n_dtcm, n_ocram))

    # ---- PJRC
    if pjrc:
        t = open(pjrc, encoding='latin-1').read()
        body = t[t.index('FlexSPI_NOR_Config[128] = {'):]
        body = body[:body.index('};')]
        body = re.sub(r'//[^\n]*', '', body)
        body = re.sub(r'#if defined\(ARDUINO_TEENSY40\)\s*0x00200000,\s*#elif defined\(ARDUINO_TEENSY41\)\s*(0x[0-9A-Fa-f]+),\s*#elif.*?#endif', r'\1,', body, flags=re.S)
        words = [int(x, 0) for x in re.findall(r'\b(0x[0-9A-Fa-f]+|\d+)\b', body.split('{', 1)[1])]
        ours = list(struct.unpack('<128I', img[:512]))
        diff = [i for i in range(128) if i >= len(words) or words[i] != ours[i]]
        check(len(words) == 128 and not diff, 'FCB identical, word for word, to PJRC\'s Teensy 4.1 FCB (teensy4/bootdata.c)', 'words differ at %s' % diff[:10])
    print('[boot] %d failures' % fails)
    return fails

if __name__ == '__main__':
    sys.exit(main(sys.argv))
