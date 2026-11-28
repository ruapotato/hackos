#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# extract_facts.py BOOTLOADER_DIR ARDUINO_DIR > feather_facts.txt
#
# Reads Adafruit's nRF52 bootloader (MIT) and Arduino core (variant files:
# LGPL-2.1) checkouts AS DATA and prints the facts Hamnix Micro's Feather port
# depends on, one per line: NAME VALUE  # where it comes from.  Only these
# extracted numbers are committed (tests/nrf52/feather_facts.txt), with the
# commits and file hashes; none of Adafruit's code is copied.
# tests/nrf52/check_image.py and check_pins.py check the port against the
# committed table; run_all.sh re-extracts and compares when the checkouts
# are given (ADAFRUIT_BOOTLOADER=..., ADAFRUIT_ARDUINO=...).
import hashlib, os, re, subprocess, sys

bl, ar = sys.argv[1], sys.argv[2]
out = []
used = []


def rd(base, rel):
    p = os.path.join(base, rel)
    used.append((base, rel, hashlib.sha256(open(p, 'rb').read()).hexdigest()))
    return open(p).read()


def fact(name, value, src):
    out.append(f"{name} {value}  # {src}")


def pinnum(s):
    m = re.match(r'PINNUM\(\s*(\d+)\s*,\s*0*(\d+)\s*\)', s)
    return int(m.group(1)) * 32 + int(m.group(2))


for board, key in (('feather_nrf52840_express', 'EXPRESS'), ('feather_nrf52840_sense', 'SENSE')):
    h = rd(bl, f'src/boards/{board}/board.h')
    g = lambda n: re.search(rf'#define\s+{n}\s+(.+?)\s*(?://.*)?$', h, re.M).group(1).strip()
    fact(f'BL_LED_PRIMARY_{key}', pinnum(g('LED_PRIMARY_PIN')), f'bootloader src/boards/{board}/board.h LED_PRIMARY_PIN')
    fact(f'BL_USB_VID_{key}', hex(int(g('USB_DESC_VID'), 0)), f'bootloader src/boards/{board}/board.h USB_DESC_VID')
    fact(f'BL_UF2_PID_{key}', hex(int(g('USB_DESC_UF2_PID'), 0)), f'bootloader src/boards/{board}/board.h USB_DESC_UF2_PID')
    fact(f'BL_VOLUME_{key}', g('UF2_VOLUME_LABEL').strip('"'), f'bootloader src/boards/{board}/board.h UF2_VOLUME_LABEL')
    v = rd(ar, f'variants/{board}/variant.cpp')
    vh = rd(ar, f'variants/{board}/variant.h')
    pins = [int(x) for x in re.findall(r'^\s*(\d+(?:\+\d+)?)\s*,\s*//\s*D\d+', v.replace('32+14', '46'), re.M)]
    gv = lambda n: int(re.search(rf'#define\s+{n}\s+\(?(\d+)\)?', vh).group(1))
    fact(f'AR_SERIAL1_TX_{key}', pins[gv('PIN_SERIAL1_TX')], f'Arduino variants/{board}: g_ADigitalPinMap[PIN_SERIAL1_TX = {gv("PIN_SERIAL1_TX")}]')
    fact(f'AR_SERIAL1_RX_{key}', pins[gv('PIN_SERIAL1_RX')], f'Arduino variants/{board}: g_ADigitalPinMap[PIN_SERIAL1_RX = {gv("PIN_SERIAL1_RX")}]')
    fact(f'AR_LED_RED_{key}', pins[gv('PIN_LED1')], f'Arduino variants/{board}: g_ADigitalPinMap[PIN_LED1 = LED_RED = {gv("PIN_LED1")}]')
ck = rd(bl, 'src/usb/uf2/configkeys.h')
for n in ('CFG_MAGIC0', 'CFG_MAGIC1', 'CFG_BOOTLOADER_BOARD_ID'):
    fact(f'BL_{n}', hex(int(re.search(rf'#define {n} (\w+)', ck).group(1), 0)), 'bootloader src/usb/uf2/configkeys.h')
ld = rd(bl, 'linker/nrf52840.ld')
fact('BL_FLASH_ORIGIN', hex(int(re.search(r'FLASH \(rx\) : ORIGIN = (0x\w+)', ld).group(1), 16)), 'bootloader linker/nrf52840.ld FLASH ORIGIN')
m = re.search(r'BOOTLOADER_CONFIG \(r\): ORIGIN = (0x\w+) - (\d+)K', ld)
fact('BL_CONFIG_ADDR', hex(int(m.group(1), 16) - int(m.group(2)) * 1024), 'bootloader linker/nrf52840.ld BOOTLOADER_CONFIG ORIGIN')
dt = rd(bl, 'lib/sdk11/components/libraries/bootloader_dfu/dfu_types.h')
sec = dt[dt.index('defined(NRF52840_XXAA)'):]
fact('BL_REGION_START', hex(int(re.search(r'BOOTLOADER_REGION_START\s+(0x\w+)', sec).group(1), 16)), 'bootloader dfu_types.h BOOTLOADER_REGION_START (nRF52840)')
cm = rd(bl, 'CMakeLists.txt')
sec = cm[cm.index('MCU_VARIANT STREQUAL "nrf52840"'):]
a, b = re.search(r'DFU_APP_DATA_RESERVED (\d+)\*(\d+)', sec).groups()
fact('BL_APP_DATA_RESERVED', hex(int(a) * int(b)), 'bootloader CMakeLists.txt DFU_APP_DATA_RESERVED (nrf52840)')
mbr = rd(bl, 'lib/softdevice/s140_nrf52_6.1.1/s140_nrf52_6.1.1_API/include/nrf52/nrf_mbr.h')
fact('BL_MBR_SIZE', hex(int(re.search(r'#define MBR_SIZE\s+\((0x\w+)\)', mbr).group(1), 16)), 'S140 6.1.1 API nrf_mbr.h MBR_SIZE')
mn = rd(bl, 'src/main.c')
fact('BL_SINGLE_TAP_MAGIC', re.search(r'DFU_BANK_0_REGION_START \+ (0x\w+)\)\) == (0x\w+)', mn).group(2) + '@' + re.search(r'DFU_BANK_0_REGION_START \+ (0x\w+)', mn).group(1), 'bootloader src/main.c APP_ASKS_FOR_SINGLE_TAP_RESET')
cs = rd(bl, 'cmake/softdevice.cmake')
fact('BL_SD_DEFAULT_NRF52840', re.search(r'else \(\)\s*\n\s*set\(SD_VERSION ([\d.]+)\)', cs).group(1), 'bootloader cmake/softdevice.cmake (non-nrf52833 default)')


def hexword(path, addr):
    mem = {}
    base = 0
    for line in open(path):
        r = bytes.fromhex(line.strip()[1:])
        n, a, t = r[0], (r[1] << 8) | r[2], r[3]
        if t == 0:
            for i in range(n):
                mem[base + a + i] = r[4 + i]
        elif t == 4:
            base = int.from_bytes(r[4:6], 'big') << 16
        elif t == 2:
            base = int.from_bytes(r[4:6], 'big') << 4
    return int.from_bytes(bytes(mem[addr + i] for i in range(4)), 'little')


for ver in ('6.1.1', '7.3.0'):
    p = f'lib/softdevice/s140_nrf52_{ver}/s140_nrf52_{ver}_softdevice.hex'
    if os.path.exists(os.path.join(bl, p)):
        rd(bl, p)
        # nrf_sdm.h: SD_SIZE_OFFSET = SOFTDEVICE_INFO_STRUCT_OFFSET (0x2000) + 8, from MBR_SIZE
        fact(f'SD_S140_{ver.replace(".", "_")}_APP_START', hex(hexword(os.path.join(bl, p), 0x1000 + 0x2008)), f'{p}: SD_SIZE_GET(MBR_SIZE), the word at 0x3008')
rm = rd(bl, 'README.md')
fact('BL_UF2_FAMILY_NRF52840', re.search(r'family as \*\*(0x[0-9A-Fa-f]+)\*\* \(nRF52840\)', rm).group(1).lower(), 'bootloader README.md')
print("# Facts extracted by tests/nrf52/extract_facts.py from Adafruit's sources (read as data).")
for base, name in ((bl, 'Adafruit_nRF52_Bootloader'), (ar, 'Adafruit_nRF52_Arduino')):
    c = subprocess.run(['git', '-C', base, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    print(f"# {name} commit {c}")
for base, rel, h in used:
    print(f"# sha256 {h} {'bootloader' if base == bl else 'arduino'}:{rel}")
print('\n'.join(out))
