#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# check_image.py FACTS BUILD_DIR
#
# The Feather nRF52840 image against what Adafruit's UF2 bootloader needs
# (FACTS: tests/nrf52/feather_facts.txt, extracted from its sources) and
# against itself: the ELF (llvm-readelf/llvm-nm), the Intel HEX, the UF2
# file and the pin and bootloader constants of boards/feather_nrf52840/
# board.ad.  Prints one line per check; exit status = failures.
import re, struct, subprocess, sys

facts = {}
for line in open(sys.argv[1]):
    if line.startswith('#') or not line.strip():
        continue
    k, v = line.split('#')[0].split()
    facts[k] = v
B = sys.argv[2]
fails = 0
n = 0


def check(cond, msg):
    global fails, n
    n += 1
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        fails += 1


def num(k):
    return int(facts[k].split('@')[0], 0)


syms = {}
for line in subprocess.run(['llvm-nm', f'{B}/hackos.elf'], capture_output=True, text=True).stdout.split('\n'):
    p = line.split()
    if len(p) == 3:
        syms[p[2]] = int(p[0], 16)

app = num('SD_S140_6_1_1_APP_START')
mbr = num('BL_MBR_SIZE')
bl_start = num('BL_REGION_START')
user_end = bl_start - num('BL_APP_DATA_RESERVED')
check(num('BL_FLASH_ORIGIN') == bl_start, f"bootloader at 0x{bl_start:x} (linker script and dfu_types.h agree)")
check(facts['BL_SD_DEFAULT_NRF52840'] == '6.1.1', "Adafruit's nRF52840 bootloaders are built with S140 6.1.1")
mk = open('boards/feather_nrf52840/board.mk').read()
check(re.search(r'^NRF_APP_START \?= 0x0*26000$', mk, re.M) is not None and app == 0x26000,
      f"NRF_APP_START 0x26000 = S140 6.1.1's own size word (SD_SIZE_GET); 7.3.0 would be 0x{num('SD_S140_7_3_0_APP_START'):x}")
check(syms['hackos_vectors'] == app and syms['__vectors_start'] == app, f"vector table at the application start 0x{app:x}")

ph = subprocess.run(['llvm-readelf', '-l', f'{B}/hackos.elf'], capture_output=True, text=True).stdout
loads = [l.split() for l in ph.split('\n') if l.strip().startswith('LOAD')]
bad = [l for l in loads if int(l[4], 16) and not (app <= int(l[3], 16) < user_end)]
check(loads and not bad, f"every ELF load segment with file contents has its load address inside 0x{app:x}..0x{user_end:x} "
      f"({len(loads)} segments; programming the ELF over SWD writes nothing else)")

# the image's bytes, from the HEX
mem = {}
base = 0
for line in open(f'{B}/hackos.hex'):
    r = bytes.fromhex(line.strip()[1:])
    c, a, t = r[0], (r[1] << 8) | r[2], r[3]
    if t == 0:
        for i in range(c):
            mem[base + a + i] = r[4 + i]
    elif t == 4:
        base = int.from_bytes(r[4:6], 'big') << 16
    elif t == 2:
        base = int.from_bytes(r[4:6], 'big') << 4
lo, hi = min(mem), max(mem) + 1
check(lo == app, f"the HEX starts at 0x{lo:x}: nothing for the MBR (0..0x{mbr:x}) or the SoftDevice (0x{mbr:x}..0x{app:x})")
check(hi <= user_end, f"the HEX ends at 0x{hi:x}, below the bootloader's application-data area (0x{user_end:x}..0x{bl_start:x})")
w = lambda a: int.from_bytes(bytes(mem.get(a + i, 0xFF) for i in range(4)), 'little')
sp, rst = w(app), w(app + 4)
check(0x20000000 <= sp <= 0x20040000 and sp % 4 == 0 and sp == syms['__stack_top'],
      f"word 0 = initial MSP 0x{sp:08x} = __stack_top, in RAM, aligned (bootloader_app_is_valid)")
check(rst & 1 and app <= rst < bl_start and (rst & ~1) == syms['Reset_Handler'],
      f"word 1 = Reset_Handler|1 = 0x{rst:08x}, inside the application area (bootloader_app_is_valid)")
for i, s in ((11, 'svc_handler'), (14, 'pendsv_handler'), (16 + 2, 'uart0_rx_handler'), (16 + 17, 'board_rtc1_handler')):
    check(w(app + 4 * i) == syms[s] | 1, f"vector {i} = {s}")
others = [w(app + 4 * i) for i in range(16, 64) if i not in (18, 33)]
check(all(x == syms['irq_default_handler'] | 1 for x in others), "the other 46 interrupt vectors are the default handler")
magic, off = facts['BL_SINGLE_TAP_MAGIC'].split('@')
check(w(app + int(off, 0)) != int(magic, 0), f"no {magic} at 0x{app + int(off, 0):x} (it would make one reset enter the bootloader)")
rlo, rhi = syms['__romfs_start'], syms['__romfs_end']
check(rlo == 0x60000, f"the ROM table (/bin) at 0x{rlo:x}")
win = 256
while not ((rlo - (rlo & ~(win - 1))) % (win // 8) == 0 and rhi <= (rlo & ~(win - 1)) + win):
    win <<= 1
wbase = rlo & ~(win - 1)
first, last = (rlo - wbase) // (win // 8), -(-(rhi - wbase) // (win // 8))
check(wbase % win == 0 and wbase + win <= 0x100000,
      f"its MPU region: {win // 1024} KB at 0x{wbase:x}, sub-regions {first}..{last - 1} of 8 enabled (0x{wbase + first * win // 8:x}..0x{wbase + last * win // 8:x})")
check(syms['__text_end'] <= wbase + first * (win // 8), f"kernel code ends at 0x{syms['__text_end']:x}, below the part of the region open to processes")
check(syms['__flash_end'] <= 0xAD000,
      f"the image ends at 0x{syms['__flash_end']:x}, below 0xAD000 (Adafruit bootloader 0.2.6 silently drops UF2 blocks from there on); {(0xAD000 - syms['__flash_end']) // 1024} KB to spare")
check(syms['__prog_end'] == 0x20040000 and syms['__heap_end'] <= syms['__prog_start'], "the program arena ends at the end of RAM, after the kernel heap")
check(syms['__prog_start'] <= 0x20020000 <= syms['__prog_end'] - 0x1C000, "a 112 KB shell block fits at 0x20020000 (its 128 KB boundary)")

# UF2
data = open(f'{B}/hackos.uf2', 'rb').read()
check(len(data) % 512 == 0 and len(data) > 0, f"UF2: {len(data) // 512} blocks of 512 bytes")
blocks = [data[i:i + 512] for i in range(0, len(data), 512)]
fam = num('BL_UF2_FAMILY_NRF52840')
good = True
seen = {}
for i, b in enumerate(blocks):
    m0, m1, flags, addr, size, bno, nblk, family = struct.unpack('<8I', b[:32])
    end, = struct.unpack('<I', b[508:])
    if (m0, m1, end) != (0x0A324655, 0x9E5D5157, 0x0AB16F30) or flags != 0x2000 or size != 256 or family != fam \
            or bno != i or nblk != len(blocks) or addr % 256 or not (app <= addr and addr + 256 <= user_end) or addr in seen:
        good = False
        print(f"  block {i}: magic {m0:x}/{m1:x}/{end:x} flags {flags:x} addr {addr:x} size {size} no {bno}/{nblk} family {family:x}")
        break
    seen[addr] = b[32:32 + 256]
    if b[32 + 256:508] != bytes(508 - 32 - 256):
        good = False
        print(f"  block {i}: padding after the payload is not zero")
        break
check(good, f"UF2: every block has both start magics and the end magic, flags 0x2000 (family id), family 0x{fam:08x}, "
      f"256-byte payload at a 256-aligned address inside 0x{app:x}..0x{user_end:x}, block numbers 0..{len(blocks) - 1} of {len(blocks)}")
same = all(seen.get(a // 256 * 256, b'\xff' * 256)[a % 256] == v for a, v in mem.items())
check(same and set(seen) == {a // 256 * 256 for a in mem}, "UF2: its blocks hold exactly the HEX's bytes (gaps 0xFF)")
check(len(blocks) < 1024 * 1024 // 256 + 100, "UF2: fewer blocks than the bootloader's MAX_BLOCKS (CFG_UF2_FLASH_SIZE/256 + 100)")

# board.ad constants against the extracted pin facts
bd = open('boards/feather_nrf52840/board.ad').read()
c = lambda name: int(re.search(rf'^{name}: \w+ = (0x[0-9A-Fa-f]+|\d+)', bd, re.M).group(1), 0)
check(c('PIN_TX') == num('AR_SERIAL1_TX_EXPRESS') == num('AR_SERIAL1_TX_SENSE'), f"TX pin P0.{c('PIN_TX')} = Arduino Serial1 TX (D0) on the Express and the Sense")
check(c('PIN_RX') == num('AR_SERIAL1_RX_EXPRESS') == num('AR_SERIAL1_RX_SENSE'), f"RX pin P0.{c('PIN_RX')} = Arduino Serial1 RX (D1) on both")
check(c('PIN_LED_EXPRESS') == num('AR_LED_RED_EXPRESS') == num('BL_LED_PRIMARY_EXPRESS'), "red LED P1.15 (Express): Arduino LED_RED and the bootloader's LED_PRIMARY_PIN")
check(c('PIN_LED_SENSE') == num('AR_LED_RED_SENSE') == num('BL_LED_PRIMARY_SENSE'), "red LED P1.09 (Sense): Arduino LED_RED and the bootloader's LED_PRIMARY_PIN")
check(c('BOOTCFG') == num('BL_CONFIG_ADDR'), "the bootloader's CF2 configuration block at 0xFD800")
check(c('CFG_MAGIC0') == num('BL_CFG_MAGIC0') and c('CFG_MAGIC1') == num('BL_CFG_MAGIC1') and c('CFG_BOARD_ID') == num('BL_CFG_BOOTLOADER_BOARD_ID'), "CF2 magics and the board-id key")
check(c('ID_EXPRESS') == (num('BL_USB_VID_EXPRESS') << 16 | num('BL_UF2_PID_EXPRESS')), "board id of the Express (VID << 16 | UF2 PID)")
check(c('ID_SENSE') == (num('BL_USB_VID_SENSE') << 16 | num('BL_UF2_PID_SENSE')), "board id of the Sense")
check(c('XIP_WINDOW') == syms['__romfs_start'], "board.ad's XIP_WINDOW = the ROM table's address")
doc = open('docs/boards/feather-nrf52840.md').read() if __import__('os').path.exists('docs/boards/feather-nrf52840.md') else ''
check(facts['BL_VOLUME_EXPRESS'] in doc, f"the doc names the bootloader drive {facts['BL_VOLUME_EXPRESS']}")
print(f"check_image: {n} checks, {fails} failures")
sys.exit(fails)
