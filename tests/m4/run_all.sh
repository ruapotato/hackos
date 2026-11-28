#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# `make test-m4`: HackOS on QEMU's Cortex-M4F machine (`-M mps2-an386`,
# BOARD=qemu-m4).  The same kernel test image and the same shell session as
# `make test` (tests/run_all.sh sections 5 and 8), built for the M4:
# single-precision FPU, float64 in software, the 8-region MPU.  Before that,
# two static checks that the build really is what it claims.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
B=build/qemu-m4
fails=0
ok()  { echo "[test-m4] ok: $1"; }
bad() { echo "[test-m4] FAIL: $1"; fails=$((fails+1)); }
echo "[test-m4] === static: the images are Cortex-M4F code"
for img in ktest hackos; do
    n="$(grep -cE '\sv(add|sub|mul|div|sqrt|cmp|cvt)[a-z]*\.f64|\svcvt\.[su]32\.f64' $B/$img.lst)"
    [ "$n" = 0 ] && ok "$img: no double-precision FPU instruction" || bad "$img: $n double-precision FPU instructions"
done
n="$(grep -cE '<__aeabi_d(add|mul|div|sub)>:' $B/ktest.lst)"
[ "$n" -ge 3 ] && ok "ktest: float64 arithmetic is linked as software ($n of the __aeabi_d* helpers)" || bad "ktest: software float64 helpers missing"
n="$(llvm-nm $B/user/hamsh.elf | grep -cE ' T __aeabi_d(add|mul|div)$')"
[ "$n" = 3 ] && ok "the shell links software float64 too" || bad "hamsh: $n of 3 software float64 helpers"
llvm-objdump -d --mcpu=cortex-m4 $B/user/hamsh.elf | grep -qE '\sv(add|sub|mul|div)\.f64' && bad "hamsh has double-precision FPU instructions" || ok "hamsh: no double-precision FPU instruction"
cpu="$(llvm-readelf -A $B/ktest.o 2>/dev/null | grep -A1 'TagName: CPU_name' | sed -n 's/.*Value: //p')"
[ "$cpu" = cortex-m4 ] && ok "ktest.o is built for $cpu" || bad "ktest.o is built for '$cpu'"
HACKOS_B=$B HACKOS_MACHINE=mps2-an386 HACKOS_XP=21 HACKOS_ONLY="5 8" ADDER="${ADDER:-../adder}" bash tests/run_all.sh; rc=$?
[ $rc -eq 0 ] || fails=$((fails+1))
echo
if [ $fails -eq 0 ]; then echo "[test-m4] ALL CHECKS PASSED"; exit 0; fi
echo "[test-m4] $fails CHECK GROUP(S) FAILED"; exit 1
