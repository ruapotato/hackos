#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# The uSDHC and SD card drivers against QEMU's uSDHC and SD card models
# (-M mcimx6ul-evk; see tests/imxrt/usdhc_qemu_main.ad).  Three runs:
#   sdsc   a 2 MiB card image   (QEMU: standard capacity, byte addresses)
#   sdhc   a 4 GiB sparse image (QEMU: high capacity, block addresses)
#   none   no card
# After each run with a card, the image file is read here to check that the
# blocks the driver wrote landed at the right offsets.
# Prints "ok:" / "FAIL:" lines; exit status = number of failures.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ADDER="${ADDER:-../adder}"
AC="$(cd "$ADDER" && pwd)/build/cutover/host_ac.elf"
B=build/imxrt/a7; mkdir -p $B
fails=0
ok()  { echo "[usdhc] ok: $1"; }
bad() { echo "[usdhc] FAIL: $1"; fails=$((fails+1)); }
CPU="--target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb"
bash scripts/mkroot.sh $B/root mps2_an500 soc/imxrt/delay.ad=tests/imxrt/qemu_a7/delay.ad || exit 1
(cd $B/root && "$AC" --backend=llvm --target=thumbv7em-none-eabihf tests/imxrt/usdhc_qemu_main.ad "$(pwd)/../t.ll") > $B/compile.log 2>&1 || { cat $B/compile.log; exit 1; }
clang $CPU -O2 -ffreestanding -fno-pic -ffunction-sections -fdata-sections -Wno-override-module -c $B/t.ll -o $B/t.o || exit 1
clang $CPU -ffreestanding -c arch/armv7m/aeabi.S -o $B/aeabi.o || exit 1
clang --target=armv7a-none-eabihf -mcpu=cortex-a7 -c tests/imxrt/qemu_a7/entry.S -o $B/entry.o || exit 1
ld.lld -T tests/imxrt/qemu_a7/link.ld --gc-sections -nostdlib -static -o $B/usdhc_test.elf $B/entry.o $B/aeabi.o $B/t.o || exit 1

mkimg() {  # mkimg <file> <bytes>
    python3 -I - "$1" "$2" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
blocks = size // 512
def blk(lba):
    return bytes(((lba * 31 + o * 7 + 1) & 255) for o in range(512))
with open(path, 'wb') as f:
    f.truncate(size)
    for lba in list(range(0, 4096)) + list(range(blocks - 64, blocks)):
        f.seek(lba * 512); f.write(blk(lba))
PY
}
verify_img() {  # verify_img <file>: blocks written by the test, and their neighbours
    python3 -I - "$1" <<'PY'
import sys
f = open(sys.argv[1], 'rb')
def blk(lba, x=0):
    return bytes((((lba * 31 + o * 7 + 1) & 255) ^ x) for o in range(512))
def at(lba):
    f.seek(lba * 512); return f.read(512)
bad = []
for lba in [2000] + list(range(3000, 3008)):
    if at(lba) != blk(lba, 0xA5): bad.append('%d not written' % lba)
for lba in (3500, 3501):
    if at(lba) != blk(lba, 0x5A): bad.append('%d not written' % lba)
for lba in (1999, 2001, 2999, 3008, 3499, 3502, 0, 4095):
    if at(lba) != blk(lba): bad.append('%d changed' % lba)
print('image: ' + ('; '.join(bad) if bad else 'the written blocks are at the right offsets, the neighbours untouched'))
sys.exit(1 if bad else 0)
PY
}
run() {  # run <name> [drive args]
    local log=$B/$1.log
    timeout 60 qemu-system-arm -M mcimx6ul-evk -m 128M -nographic -monitor none -serial stdio ${2:-} -kernel $B/usdhc_test.elf </dev/null >$log 2>$log.err &
    local pid=$! i=0
    while ! grep -q '\[usdhc-test\] done' $log 2>/dev/null; do
        i=$((i+1)); [ $i -gt 400 ] && break
        kill -0 $pid 2>/dev/null || break
        sleep 0.1
    done
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    tr -d '\r' < $log > $log.txt
    sed 's/^/    /' $log.txt
    local nf; nf="$(sed -n 's/^\[usdhc-test\] done \([0-9]*\)$/\1/p' $log.txt)"
    [ -n "$nf" ] || { bad "$1: the test did not finish"; return; }
    [ "$(grep -c '^FAIL ' $log.txt)" = 0 ] && [ "$nf" = 0 ] && ok "$1: $(grep -c '^PASS ' $log.txt) checks pass" || bad "$1: $nf checks fail"
}
mkimg $B/sdsc.img $((2*1024*1024))
run sdsc "-drive if=sd,index=0,format=raw,file=$B/sdsc.img"
grep -q 'INFO card v2=1 hc=0 ' $B/sdsc.log.txt && ok "sdsc: identified as a version 2 standard-capacity card" || bad "sdsc: not identified as v2 SDSC"
grep -q ' sectors=4096 ' $B/sdsc.log.txt && ok "sdsc: 4096 sectors from the CSD (version 1.0 layout)" || bad "sdsc: wrong capacity"
verify_img $B/sdsc.img && ok "sdsc: image file checked from the host" || bad "sdsc: image file"
mkimg $B/sdhc.img $((4*1024*1024*1024))
run sdhc "-drive if=sd,index=0,format=raw,file=$B/sdhc.img"
grep -q 'INFO card v2=1 hc=1 ' $B/sdhc.log.txt && ok "sdhc: identified as a high-capacity card" || bad "sdhc: not identified as SDHC"
grep -q ' sectors=8388608 ' $B/sdhc.log.txt && ok "sdhc: 8388608 sectors from the CSD (version 2.0 layout)" || bad "sdhc: wrong capacity"
verify_img $B/sdhc.img && ok "sdhc: image file checked from the host" || bad "sdhc: image file"
rm -f $B/sdhc.img
run none ""
grep -q 'INFO sd_init rc=10 (negated) at CMD41' $B/none.log.txt && ok "none: no card is reported as such (CMD55/ACMD41 time out)" || bad "none: unexpected result"
echo "[usdhc] $fails failures"
exit $fails
