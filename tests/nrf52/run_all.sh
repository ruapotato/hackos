#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# make test-nrf52: everything that can be checked about BOARD=feather-nrf52840
# without the board.  Each step's log goes to build/nrf52/<step>.log.
#   third_party  the Nordic headers and compiler-rt files match UPSTREAM
#   regs         every register constant against Nordic's nrf52840.h (and a
#                deliberately wrong one is caught)
#   facts        (with ADAFRUIT_BOOTLOADER= and ADAFRUIT_ARDUINO= checkouts)
#                the committed feather_facts.txt re-extracted from them
#   image        vector table, memory map, HEX and UF2 against the
#                bootloader's rules; pins against Adafruit's tables
#   code         no double-precision FPU instruction anywhere (the M4F has
#                none), the soft-double helpers linked, every program an
#                RWPI executable with no load-time relocation
#   renode       the image in Renode's nRF52840 machine, the shell session
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
L=build/nrf52; mkdir -p $L
B=build/feather-nrf52840
failed=0
step() {
    local name="$1"; shift
    if "$@" > $L/$name.log 2>&1; then
        echo "[nrf52] ok: $name ($(grep -c '' $L/$name.log) lines in $L/$name.log)"
    else
        rc=$?
        if [ $rc = 77 ]; then echo "[nrf52] SKIP: $name ($(tail -1 $L/$name.log))"; return; fi
        echo "[nrf52] FAIL: $name"; sed 's/^/    /' $L/$name.log | grep -E 'FAIL|error|Error' | head -20; failed=$((failed+1))
    fi
}

third_party() {
    local bad=0
    for d in third_party/nordic-mdk-nrf52840 third_party/llvm-compiler-rt-builtins; do
        n=0
        while read -r h f; do
            n=$((n+1))
            [ "$(sha256sum "$d/$f" | cut -d' ' -f1)" = "$h" ] || { echo "FAIL: $d/$f differs from UPSTREAM"; bad=1; }
        done < <(grep -E '^[0-9a-f]{64}  ' $d/UPSTREAM)
        [ $n -gt 3 ] && echo "ok: $n files of $d match their hashes" || { echo "FAIL: $d: $n hashes"; bad=1; }
    done
    return $bad
}

regs() {
    python3 -I tests/nrf52/check_regs.py third_party/nordic-mdk-nrf52840 soc/nrf52840/soc.ad soc/nrf52/*.ad boards/feather_nrf52840/board.ad || return 1
    sed 's/^UARTE_BAUD_115200: uint32 = 0x01D60000/UARTE_BAUD_115200: uint32 = 0x01D7E000/' soc/nrf52/uarte.ad > $L/uarte_wrong.ad
    if python3 -I tests/nrf52/check_regs.py third_party/nordic-mdk-nrf52840 $L/uarte_wrong.ad > $L/regs_neg.log; then
        echo "FAIL: a wrong value (UART's 115200 divisor in UARTE's register) was not caught"; return 1
    fi
    grep FAIL $L/regs_neg.log; echo "ok: ... and a wrong one is caught (the legacy UART's 115200 value, the mistake the checker found)"
}

facts() {
    if [ -z "${ADAFRUIT_BOOTLOADER:-}" ] || [ -z "${ADAFRUIT_ARDUINO:-}" ]; then
        echo "no ADAFRUIT_BOOTLOADER/ADAFRUIT_ARDUINO checkouts given: using the committed tests/nrf52/feather_facts.txt"; return 77
    fi
    python3 -I tests/nrf52/extract_facts.py "$ADAFRUIT_BOOTLOADER" "$ADAFRUIT_ARDUINO" > $L/facts.txt || return 1
    diff tests/nrf52/feather_facts.txt $L/facts.txt && echo "ok: the facts table is what those checkouts say"
}

code() {
    local bad=0
    for f in $B/hackos.elf $B/user/*.elf; do
        n=$(llvm-objdump -d --mcpu=cortex-m4 --no-show-raw-insn $f | grep -cE '\bv(add|sub|mul|div|sqrt|cmp|cmpe|cvt|fma|fms|nmul|neg|abs|mla|mls)[a-z]*\.f64\b|\.f64\.' )
        [ "$n" = 0 ] || { echo "FAIL: $f has $n double-precision FPU instructions (undefined on the M4F)"; bad=1; }
    done
    echo "ok: no double-precision FPU arithmetic in the kernel or any program"
    # the shell computes in float64 (its numbers), so it must carry the
    # helpers; the kernel image keeps none after --gc-sections (nothing it
    # runs uses float64), which the successful link already proves is fine
    n=$(llvm-nm $B/user/hamsh.elf | grep -cE ' T (__aeabi_dadd|__aeabi_dmul|__aeabi_ddiv|__aeabi_dcmplt)$')
    [ "$n" = 4 ] && echo "ok: hamsh links compiler-rt's __aeabi_dadd/dmul/ddiv/dcmplt" || { echo "FAIL: hamsh: $n of the soft-double helpers"; bad=1; }
    for f in $B/user/*.elf; do
        h=$(llvm-readelf -h -l $f)
        echo "$h" | grep -q 'Type: *EXEC' && [ "$(echo "$h" | grep -c ' LOAD ')" = 2 ] && echo "$h" | grep -qE 'GNU_STACK +0x0+ 0x0+ 0x0+ 0x0+ 0x0*[1-9a-f]' \
            || { echo "FAIL: $f is not a two-segment RWPI executable with a stack size"; bad=1; }
        off=$(echo "$h" | awk '$1=="LOAD"{print $2; exit}')
        [ $((off % 8)) = 0 ] || { echo "FAIL: $f: code at file offset $off, not 8-aligned (the loader would copy it)"; bad=1; }
        o=$B/user/$(basename $f .elf).o
        n=$(llvm-readelf -r $o | grep -v '\.debug\|\.ARM\.ex' | grep -c 'R_ARM_ABS32')
        [ "$n" = 0 ] || { echo "FAIL: $o has $n absolute relocations (an RWPI program cannot have them)"; bad=1; }
    done
    echo "ok: $(ls $B/user/*.elf | wc -l) programs: ET_EXEC, code + data segments, PT_GNU_STACK set, code 8-aligned in the file, no absolute relocations"
    return $bad
}

[ -f $B/hackos.uf2 ] || { echo "[nrf52] FAIL: $B/hackos.uf2 missing (make BOARD=feather-nrf52840)"; exit 1; }
step third_party third_party
step regs regs
step facts facts
step image python3 -I tests/nrf52/check_image.py tests/nrf52/feather_facts.txt $B
step code code
step renode bash tests/nrf52/renode_session.sh
echo "[nrf52] $failed failed steps"
exit $failed
