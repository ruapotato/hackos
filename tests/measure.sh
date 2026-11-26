#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# HackOS: measure what Adder's 64-bit value model costs on Cortex-M7.
# Compiles tests/measure/cost.ad (Adder, LLVM lane) and tests/measure/cost.c
# (C) with the same clang, same flags, and prints per-function code size and
# instruction count, plus the image size.  `make measure`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ADDER="${ADDER:-../adder}"
CLANG="${CLANG:-clang}"; OBJDUMP="${OBJDUMP:-llvm-objdump}"; SIZE="${SIZE:-llvm-size}"
B=build/measure; mkdir -p $B
CF="--target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb -ffreestanding -fno-pic -Wno-override-module"
bytes() { llvm-nm -S "$1" | awk -v fn="$2" '$4==fn{print strtonum("0x" $2)}'; }
insns() { awk -v fn="<$2>:" '/^[0-9a-f]+ <.*>:$/{infn=($2==fn); next} infn && /^ +[0-9a-f]+:/ && $0 !~ /\.(word|short|byte)/{n++} END{print n+0}' "$1"; }

# clang -Os does not reach functions in a .ll file (size optimisation is a
# per-function IR attribute, and the Adder compiler does not emit it), so the
# -Os row adds `optsize` to the generated IR with sed to show what the
# compiler would get if it emitted the attribute.
for OPT in -O2 -Os; do
    "$ADDER/build/cutover/host_ac.elf" --backend=llvm --target=thumbv7em-none-eabihf tests/measure/cost.ad $B/cost_ad.ll
    if [ "$OPT" = "-Os" ]; then sed -i 's/ noredzone nounwind / noredzone nounwind optsize /' $B/cost_ad.ll; fi
    $CLANG $CF $OPT -c $B/cost_ad.ll -o $B/cost_ad$OPT.o
    # -fno-builtin: the Adder side is "no-builtins" too (no loop -> memcpy idiom).
    $CLANG $CF $OPT -fno-builtin -fno-unwind-tables -fomit-frame-pointer -c tests/measure/cost.c -o $B/cost_c$OPT.o
    for k in ad c; do $OBJDUMP -d --mcpu=cortex-m7 --no-show-raw-insn $B/cost_$k$OPT.o > $B/cost_$k$OPT.dis; done
    echo "Per-function Thumb-2 code, clang $OPT$([ "$OPT" = "-Os" ] && echo " (Adder IR + optsize)"), thumbv7em-none-eabihf / cortex-m7"
    printf '%-12s | %15s | %15s | %s\n' function "Adder bytes/ins" "C bytes/ins" "bytes ratio"
    ta=0; tc=0
    for f in deref store call3 call5 sum_array list_sum bump_first copy_bytes; do
        ab=$(bytes $B/cost_ad$OPT.o $f); cb=$(bytes $B/cost_c$OPT.o $f)
        ai=$(insns $B/cost_ad$OPT.dis $f); ci=$(insns $B/cost_c$OPT.dis $f)
        ta=$((ta+ab)); tc=$((tc+cb))
        printf '%-12s | %7s / %-5s | %7s / %-5s | %s\n' $f "$ab" "$ai" "$cb" "$ci" "$(awk -v a=$ab -v c=$cb 'BEGIN{printf "%.2fx", a/c}')"
    done
    printf '%-12s | %7s         | %7s         | %s\n\n' total "$ta" "$tc" "$(awk -v a=$ta -v c=$tc 'BEGIN{printf "%.2fx", a/c}')"
done
echo "sizeof(Item {uint32 key; Item *next; uint8 *data}):"
echo "  Adder: $(awk '/^define .*@sizeof_item\(/{f=1} f&&/ret i64/{print $3} /^}/{f=0}' <($CLANG $CF -O2 -S -emit-llvm $B/cost_ad.ll -o -)) bytes   C: $(awk '/<sizeof_item>:/{f=1;next} f&&/movs/{print strtonum(substr($4,2)); exit}' $B/cost_c-O2.dis) bytes"
echo
if [ -f build/hackos.elf ]; then echo "Demo image:"; $SIZE build/hackos.elf; fi
