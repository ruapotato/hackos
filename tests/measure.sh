#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# Hamnix Micro: measure what Adder's 64-bit value model costs on Cortex-M7.
# Compiles tests/measure/cost.ad (Adder, LLVM lane) and tests/measure/cost.c
# (C) with the same clang, same flags, and prints per-function code size and
# instruction count, plus the image size.  `make measure`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ADDER="${ADDER:-../adder}"
CLANG="${CLANG:-clang}"; OBJDUMP="${OBJDUMP:-llvm-objdump}"; SIZE="${SIZE:-llvm-size}"
B=build/measure; mkdir -p $B
AC="$(cd "$ADDER" && pwd)/build/cutover/host_ac.elf"; MB="$(pwd)/$B"
# Kernel and program sources are compiled in the tree `make` builds for the
# board (build/root: links to the sources, `board` = boards/mps2_an500).
kc() { (cd build/root && "$AC" --backend=llvm --target=thumbv7em-none-eabihf "$@"); }
CF="--target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb -ffreestanding -fno-pic -Wno-override-module"
bytes() { llvm-nm -S "$1" | awk -v fn="$2" '$4==fn{print strtonum("0x" $2)}'; }
insns() { awk -v fn="<$2>:" '/^[0-9a-f]+ <.*>:$/{infn=($2==fn); next} infn && /^ +[0-9a-f]+:/ && $0 !~ /\.(word|short|byte)/{n++} END{print n+0}' "$1"; }

# clang -Os does not reach functions in a .ll file (size optimisation is a
# per-function IR attribute), so the -Os row asks the Adder compiler for the
# attribute with --llvm-optsize.
for OPT in -O2 -Os; do
    AFLAG=""; if [ "$OPT" = "-Os" ]; then AFLAG="--llvm-optsize"; fi
    "$ADDER/build/cutover/host_ac.elf" --backend=llvm --target=thumbv7em-none-eabihf $AFLAG tests/measure/cost.ad $B/cost_ad.ll
    $CLANG $CF $OPT -c $B/cost_ad.ll -o $B/cost_ad$OPT.o
    # -fno-builtin: the Adder side is "no-builtins" too (no loop -> memcpy idiom).
    $CLANG $CF $OPT -fno-builtin -fno-unwind-tables -fomit-frame-pointer -c tests/measure/cost.c -o $B/cost_c$OPT.o
    for k in ad c; do $OBJDUMP -d --mcpu=cortex-m7 --no-show-raw-insn $B/cost_$k$OPT.o > $B/cost_$k$OPT.dis; done
    echo "Per-function Thumb-2 code, clang $OPT$([ "$OPT" = "-Os" ] && echo " (Adder: --llvm-optsize)"), thumbv7em-none-eabihf / cortex-m7"
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
if [ -f build/hmicro.elf ] && [ -f build/romfs.o ] && [ -d build/root ]; then
    rom="$($SIZE -A build/romfs.o | awk '$1==".rodata.romfs"{print $2}')"
    echo "System image (kernel, init, and the programs under /bin as ROM files), -O2:"; $SIZE build/hmicro.elf
    echo "  of that text, $rom bytes are the ROM files; the kernel itself is $(( $($SIZE build/hmicro.elf | awk 'NR==2{print $1}') - rom )) bytes"
    # the same kernel with the size attribute (the ROM files unchanged)
    kc --llvm-optsize init/main.ad $MB/hmicro_os.ll >/dev/null
    $CLANG $CF -Os -ffunction-sections -fdata-sections -c $B/hmicro_os.ll -o $B/hmicro_os.o
    ld.lld -T boards/mps2_an500/link.ld --gc-sections -nostdlib -static -o $B/hmicro_os.elf build/startup.o build/aeabi.o build/cpu.o build/switch.o build/romfs.o $B/hmicro_os.o
    echo "The same with the kernel built --llvm-optsize and clang -Os:"; $SIZE $B/hmicro_os.elf
    echo "  kernel alone: $(( $($SIZE $B/hmicro_os.elf | awk 'NR==2{print $1}') - rom )) bytes"
    echo
    echo "Programs (position-independent, stripped): file size at -O2, and built --llvm-optsize / -Os"
    printf '%-8s | %9s | %9s | %s\n' program "-O2" "-Os" "memory block when running (-O2: stack + image, rounded to eighths of an MPU region)"
    UF="$CF -ffunction-sections -fdata-sections -fPIE"
    kc --llvm-optsize user/rt/rt.ad $MB/u_rt.ll >/dev/null
    $CLANG $UF -Os -c $B/u_rt.ll -o $B/u_rt.o
    for p in echo cat ls cp rm mkdir wc head grep hamsh hello ptest halt; do
        src=user/hamnix/$p.ad; [ -f $src ] || src=user/progs/$p.ad
        kc --llvm-optsize $src $MB/u_$p.ll >/dev/null
        $CLANG $UF -Os -c $B/u_$p.ll -o $B/u_$p.o
        stack=$($OBJDUMP -p build/user/$p.elf | awk '/STACK/{getline; print strtonum("0x" substr($4,3))}')
        ld.lld -pie --no-dynamic-linker --omagic -T user/rt/prog.ld --gc-sections -nostdlib -z norelro -z stack-size=$stack --defsym=__heap_size=0 -o $B/u_$p.elf build/user/crt.o build/user/aeabi.o $B/u_rt.o $B/u_$p.o
        llvm-strip --strip-all -o $B/u_$p $B/u_$p.elf
        img=$($OBJDUMP -p build/user/$p.elf | awk '/LOAD/{getline; print strtonum("0x" substr($4,3))}')
        need=$(( stack + (img + 15) / 16 * 16 )); s=256; while [ $s -lt $need ]; do s=$((s*2)); done
        blk=$(( (need + s/8 - 1) / (s/8) * (s/8) ))
        printf '%-8s | %9s | %9s | %s\n' $p "$(stat -c %s build/user/$p)" "$(stat -c %s $B/u_$p)" "$blk"
    done
fi
