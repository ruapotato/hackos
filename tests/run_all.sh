#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# HackOS test runner (called by `make test` after the images are built).
#   1. compiler-side checks from the Adder tree (IR / disassembly, no emulator)
#   2. static checks on the linked image
#   3. the demo / self-test image under QEMU mps2-an500
#   4. the fault-handler image under QEMU
# Exit status is non-zero if anything fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ADDER="${ADDER:-../adder}"
QEMU="${QEMU:-qemu-system-arm}"
NM="${NM:-llvm-nm}"
OBJDUMP="${OBJDUMP:-llvm-objdump}"
B=build
# Every check() call site in the demo is straight-line code that runs exactly
# once, so the number of PASS lines must equal the number of call sites; a
# check that silently did not run is a failure.
EXPECTED_CHECKS="$(grep -cE '^ +check\(' demo/main.ad)"
fails=0
ok()  { echo "[test] ok: $1"; }
bad() { echo "[test] FAIL: $1"; fails=$((fails+1)); }

run_qemu() {  # run_qemu <elf> <logfile>  -> exit status of QEMU (124 = timeout)
    timeout 60 "$QEMU" -M mps2-an500 -nographic -monitor none -serial stdio \
        -semihosting-config enable=on,target=native -kernel "$1" </dev/null >"$2" 2>"$2.err"
}

echo "[test] === 1. compiler: thumbv7em target and volatile ($ADDER/scripts/test_llvm_thumbv7em.sh)"
if bash "$ADDER/scripts/test_llvm_thumbv7em.sh" > $B/compiler_test.log 2>&1; then
    ok "compiler regression test ($(grep -c '   ok:' $B/compiler_test.log) assertions)"
else
    bad "compiler regression test (see $B/compiler_test.log)"; grep -v '   ok:' $B/compiler_test.log
fi

echo "[test] === 2. static checks on $B/hackos.elf"
undef="$("$NM" -u $B/hackos.elf | wc -l)"
[ "$undef" = 0 ] && ok "no undefined symbols" || bad "$undef undefined symbols"
vec="$("$NM" $B/hackos.elf | awk '$3=="hackos_vectors"{print $1}')"
[ "$vec" = "00000000" ] && ok "vector table at 0x00000000" || bad "vector table at $vec"
"$OBJDUMP" -s -j .text --start-address=0 --stop-address=0x40 $B/hackos.elf > $B/vectors.txt
sp="$("$NM" $B/hackos.elf | awk '$3=="__stack_top"{print $1}')"
w0="$(awk '$1=="0000"{print substr($2,7,2) substr($2,5,2) substr($2,3,2) substr($2,1,2); exit}' $B/vectors.txt)"
[ "$w0" = "$sp" ] && ok "vector 0 is the initial stack pointer (0x$sp)" || bad "vector 0 is $w0, __stack_top is $sp"
st="$("$NM" $B/hackos.elf | awk '$3=="systick_handler"{print $1}')"
w15="$(awk '$1=="0030"{print substr($5,7,2) substr($5,5,2) substr($5,3,2) substr($5,1,2); exit}' $B/vectors.txt)"
[ "$((0x$w15))" = "$((0x$st + 1))" ] && ok "vector 15 is the Adder systick_handler with the Thumb bit (0x$w15)" \
    || bad "vector 15 is $w15, systick_handler is $st"
fp="$(grep -cE 'v(mul|div|add|sub)\.f64' $B/hackos.lst)"
[ "$fp" -gt 20 ] && ok "image uses double-precision FPU instructions ($fp vmul/vdiv/vadd/vsub.f64)" || bad "only $fp f64 FPU instructions"
soft="$(grep -cE '__aeabi_d(add|sub|mul|div)|__adddf3|__muldf3' $B/hackos.lst)"
[ "$soft" = 0 ] && ok "no soft-float arithmetic calls" || bad "$soft soft-float calls"
vol="$(awk '/^define .*@test_volatile_mmio\(/{f=1} f&&/(load|store) volatile i32/{n++} /^}/{f=0} END{print n+0}' $B/hackos.ll)"
[ "$vol" = 7 ] && ok "test_volatile_mmio: 5 volatile loads + 2 volatile stores of CTRL in the IR" || bad "test_volatile_mmio has $vol volatile accesses, want 7"

echo "[test] === 3. demo / self-test under QEMU"
run_qemu $B/hackos.elf $B/hackos.out; rc=$?
cat $B/hackos.out
[ $rc -eq 0 ] && ok "QEMU exit status 0" || bad "QEMU exit status $rc (124 = timed out)"
grep -q '^HackOS 0.1 (milestone 1)' $B/hackos.out && ok "banner printed over the UART" || bad "no banner"
nfail="$(grep -c '^FAIL ' $B/hackos.out)"; npass="$(grep -c '^PASS ' $B/hackos.out)"
[ "$nfail" = 0 ] && ok "no FAIL lines" || bad "$nfail FAIL lines"
[ "$npass" = "$EXPECTED_CHECKS" ] && ok "$npass PASS lines (all $EXPECTED_CHECKS checks ran)" || bad "$npass PASS lines, expected $EXPECTED_CHECKS"
grep -q '^RESULT: PASS' $B/hackos.out && ok "RESULT: PASS" || bad "no RESULT: PASS line"

echo "[test] === 4. fault handler under QEMU (deliberate undefined instruction)"
run_qemu $B/faulttest.elf $B/faulttest.out; rc=$?
cat $B/faulttest.out
[ $rc -eq 3 ] && ok "QEMU exit status 3 (fault handler ended the run)" || bad "QEMU exit status $rc, want 3"
grep -q 'HackOS FAULT: UsageFault (exception 6)' $B/faulttest.out && ok "reported as UsageFault" || bad "not reported as UsageFault"
grep -q 'CFSR  = 0x00010000' $B/faulttest.out && ok "CFSR = 0x00010000 (UFSR.UNDEFINSTR)" || bad "CFSR not 0x00010000"
grep -q 'UFSR.UNDEFINSTR' $B/faulttest.out && ok "UNDEFINSTR decoded" || bad "UNDEFINSTR not decoded"
udf="$(awk '/\tudf\t/{sub(":","",$1); print $1; exit}' $B/faulttest.lst)"
pc="$(awk '$1=="pc"{print $3}' $B/faulttest.out)"
[ -n "$udf" ] && [ "$((pc))" = "$((0x$udf))" ] && ok "stacked pc ($pc) is the address of the udf instruction" \
    || bad "stacked pc '$pc' vs udf at '$udf'"
grep -q 'continued past udf' $B/faulttest.out && bad "execution continued past the fault" || ok "execution did not continue past the fault"

echo
if [ $fails -eq 0 ]; then echo "[test] ALL TESTS PASSED"; exit 0; fi
echo "[test] $fails TEST(S) FAILED"; exit 1
