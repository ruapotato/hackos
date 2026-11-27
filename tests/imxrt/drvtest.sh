#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# Build and run the driver test image (tests/imxrt/drvtest_main.ad): the
# i.MX RT drivers against register models, in QEMU mps2-an500.  Needs the
# QEMU objects of `make` (build/startup.o ...).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ADDER="${ADDER:-../adder}"
AC="$(cd "$ADDER" && pwd)/build/cutover/host_ac.elf"
B=build/imxrt/drv; mkdir -p $B
CPU="--target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb"
for o in startup aeabi cpu romfs; do [ -f build/$o.o ] || { echo "FAIL: build/$o.o missing (run make first)"; exit 1; }; done
bash scripts/mkroot.sh $B/root mps2_an500 soc/imxrt/reg.ad=tests/imxrt/models/reg.ad soc/imxrt/delay.ad=tests/imxrt/models/delay.ad || exit 1
(cd $B/root && "$AC" --backend=llvm --target=thumbv7em-none-eabihf tests/imxrt/drvtest_main.ad "$(pwd)/../drvtest.ll") > $B/compile.log 2>&1 || { cat $B/compile.log; exit 1; }
clang $CPU -O2 -ffreestanding -fno-pic -ffunction-sections -fdata-sections -Wno-override-module -c $B/drvtest.ll -o $B/drvtest.o || exit 1
ld.lld -T boards/mps2_an500/link.ld --gc-sections -nostdlib -static -o $B/drvtest.elf build/startup.o build/aeabi.o build/cpu.o build/romfs.o $B/drvtest.o || exit 1
timeout 120 qemu-system-arm -M mps2-an500 -nographic -monitor none -serial stdio -no-reboot -kernel $B/drvtest.elf </dev/null > $B/drvtest.out 2>&1
tr -d '\r' < $B/drvtest.out > $B/drvtest.txt
cat $B/drvtest.txt
want="$(grep -cE '^ +check\(' tests/imxrt/drvtest_main.ad)"
npass="$(grep -c '^PASS ' $B/drvtest.txt)"; nfail="$(grep -c '^FAIL ' $B/drvtest.txt)"
st="$(sed -n 's/^\[hackos\] exit status \([0-9]*\)$/\1/p' $B/drvtest.txt | tail -1)"
rc=0
[ "$nfail" = 0 ] && echo "ok: no FAIL lines" || { echo "FAIL: $nfail checks failed"; rc=1; }
[ "$npass" = "$want" ] && echo "ok: $npass PASS lines, all $want checks ran" || { echo "FAIL: $npass PASS lines, $want checks in the source"; rc=1; }
[ "$st" = 0 ] && echo "ok: exit status 0" || { echo "FAIL: exit status ${st:-none}"; rc=1; }
exit $rc
