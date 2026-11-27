#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# The Teensy 4.1's software in the Teensy's memory, in QEMU.
#
# Builds a QEMU mps2-an500 system image whose /bin holds the programs of
# build/teensy41/user/ -- the same files that go into the Teensy image, size
# patches and --llvm-optsize included -- and whose kernel carries the
# teensy41 tmpfs patch, linked with:
#   * a kernel heap of exactly the Teensy's (__heap_end - __heap_start of
#     build/teensy41/hackos.elf: what DTCM leaves after data and stacks);
#   * a program arena of exactly the Teensy's 704 KB, 1 MB aligned like its
#     0x20200000, so processes get the same MPU blocks.
# Then types the shell session of `make test` (tests/run_all.sh, part 8) at
# it.  Differences from that session, because of the memory: a script is run
# with `source` (a second shell cannot fit beside the first), and
# `hamsh FILE` is expected to fail cleanly.
# What this does NOT emulate: the Teensy's clocks and peripherals, cache and
# bus timing, and the kernel's static data living in 256 KB of DTCM (the
# sizes are the same; QEMU's RAM is larger).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ADDER="${ADDER:-../adder}"
AC="$(cd "$ADDER" && pwd)/build/cutover/host_ac.elf"
T=build/teensy41
B=build/imxrt/t41mem; mkdir -p $B
QEMU="${QEMU:-qemu-system-arm}"
fails=0
ok()  { echo "[t41mem] ok: $1"; }
bad() { echo "[t41mem] FAIL: $1"; fails=$((fails+1)); }
expect() { if grep -Eq -- "$3" "$2"; then ok "$1"; else bad "$1 (no match for /$3/)"; fi; }
for f in $T/hackos.elf $T/user/hamsh build/startup.o build/sd.img; do [ -f $f ] || { echo "FAIL: $f missing (make; make BOARD=teensy41)"; exit 1; }; done
CPU="--target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb"
heap=$(( 0x$(llvm-nm $T/hackos.elf | awk '$3=="__heap_end"{print $1}') - 0x$(llvm-nm $T/hackos.elf | awk '$3=="__heap_start"{print $1}') ))
arena=$(( 0x$(llvm-nm $T/hackos.elf | awk '$3=="__prog_end"{print $1}') - 0x$(llvm-nm $T/hackos.elf | awk '$3=="__prog_start"{print $1}') ))
echo "[t41mem] Teensy kernel heap $heap bytes, program arena $arena bytes"
bash scripts/mkroot.sh $B/root mps2_an500 boards/teensy41/patches/fs/tmpfs.ad.patch || exit 1
(cd $B/root && "$AC" --backend=llvm --target=thumbv7em-none-eabihf init/main.ad "$(pwd)/../hackos.ll") > $B/compile.log 2>&1 || { cat $B/compile.log; exit 1; }
clang $CPU -O2 -ffreestanding -fno-pic -ffunction-sections -fdata-sections -Wno-override-module -c $B/hackos.ll -o $B/hackos.o || exit 1
PROGS="hello ptest crel halt echo cat ls cp rm mkdir wc head grep hamsh"
bash scripts/mkromfs.sh $B/romfs.S $(for p in $PROGS; do echo $T/user/$p; done) || exit 1
clang $CPU -ffreestanding -c $B/romfs.S -o $B/romfs.o || exit 1
python3 - boards/mps2_an500/link.ld $B/link.ld $heap $arena <<'PY'
import sys
src, dst, heap, arena = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
s = open(src).read()
old = '''    __heap_start = ALIGN(__xbss_end, 16);
    __prog_end = __user_start;
    __prog_start = __prog_end - __prog_size;
    __heap_end = __prog_start;'''
assert old in s
s = s.replace(old, '''    /* tests/imxrt/t41mem.sh: the Teensy 4.1's kernel heap and program arena */
    __heap_start = ALIGN(__xbss_end, 16);
    __heap_end = __heap_start + %d;
    __prog_start = 0x60800000;
    __prog_end = __prog_start + %d;
    ASSERT(__heap_end <= __prog_start, "heap overlaps the arena")''' % (heap // 16 * 16, arena))
open(dst, 'w').write(s)
PY
ld.lld -T $B/link.ld --gc-sections -nostdlib -static -o $B/hackos.elf build/startup.o build/aeabi.o build/cpu.o build/switch.o $B/romfs.o $B/hackos.o || exit 1
llvm-nm $B/hackos.elf | awk '$3 ~ /^__(heap|prog)_(start|end)$/ {print "[t41mem]   " $3 " = 0x" $1}'

QFLAGS="-M mps2-an500 -nographic -monitor none -serial stdio -no-reboot"
rm -f $B/uart.in; mkfifo $B/uart.in; : > $B/shell.out
timeout 180 "$QEMU" $QFLAGS -device loader,file=build/sd.img,addr=0x20200000 -kernel $B/hackos.elf <$B/uart.in >$B/shell.out 2>$B/shell.err &
QPID=$!; exec 9>$B/uart.in
wait_for() { local n="${2:-1}" i=0; while [ "$(grep -cF -- "$1" $B/shell.out 2>/dev/null)" -lt "$n" ]; do i=$((i+1)); [ $i -gt 600 ] && return 1; kill -0 $QPID 2>/dev/null || return 1; sleep 0.1; done; }
say() { printf "$1" >&9; }
m=0
sh() { m=$((m+1)); say "$1\\r"; say 'wc < /dev/null\r'; wait_for "0 0 0" $m || { bad "no answer to command #$m ($1)"; return 1; }; }
shn() { say "$1\\r"; }
if wait_for "hamsh\$ "; then
    sh 'echo hello from hamsh'
    sh 'ls /bin'
    sh 'ls /bin | wc'
    sh 'ls /bin | grep ha'
    sh 'ls /bin | grep h | head -2 | wc'
    sh 'echo builtin in a pipeline | wc'
    sh 'echo first line > /tmp/note'
    sh 'echo second line >> /tmp/note'
    sh 'cat /tmp/note'
    sh 'wc < /tmp/note'
    sh 'cat /tmp/note | grep second > /tmp/found'
    sh 'cat /tmp/found'
    sh 'cp /tmp/note /tmp/copy'
    sh 'mkdir /tmp/dir'
    sh 'ls /tmp'
    sh 'rm /tmp/note'
    sh 'head -1 < /tmp/copy'
    shn '/bin/hello with two'
    sh 'echo status was $status'
    sh 'cat /bin/hello | wc'
    sh 'no-such-command'
    shn 'ptest peek 20000000'
    sh 'echo after the fault $status'
    shn 'ptest loop'; sleep 1; say '\x03'
    sh 'echo interrupted $status'
    sh 'ls /sd'
    sh 'cat /sd/README.TXT'
    sh 'cp /sd/PATTERN.BIN /tmp/pattern'
    sh 'cat /tmp/pattern | wc'
    sh 'cp /tmp/pattern /sd/BACK.BIN'
    sh 'cat /sd/BACK.BIN | wc'
    sh 'rm /sd/BACK.BIN'
    sh "echo 'echo script started' > /tmp/s.hsh"
    sh "echo 'ls /bin | wc > /tmp/count' >> /tmp/s.hsh"
    sh "echo 'cat /tmp/count' >> /tmp/s.hsh"
    sh "echo 'n = 6 * 7' >> /tmp/s.hsh"
    sh "echo 'for w in [\"alpha\", \"beta\"] { echo script word \$w }' >> /tmp/s.hsh"
    sh "echo 'if n == 42 { echo script n is \$n }' >> /tmp/s.hsh"
    sh "echo 'echo script piped | wc' >> /tmp/s.hsh"
    sh 'source /tmp/s.hsh'
    shn 'hamsh /tmp/s.hsh'
    sh 'echo second shell status $status'
    sh 'for i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] { echo loop $i | wc }'
    sh 'ls /tmp | wc'
    say 'halt 0\r'
else
    bad "the shell never printed its prompt"
fi
wait $QPID; rc=$?; exec 9>&-; rm -f $B/uart.in
sed 's/\r*$//; s/.*\r//; s/\x1b\[[0-9;?]*[A-Za-z]//g' < $B/shell.out > $B/shell.txt
S=$B/shell.txt
sed 's/^/    /' $S
NPROG=$(echo $PROGS | wc -w)
grep -q '^\[hackos\] exit status 0$' $S && ok "'halt 0' ended the run with status 0" || bad "the run did not end with status 0 (timeout rc $rc)"
expect "hamsh runs as a process (its banner)" $S "^hamsh . Hamnix shell"
expect "a built-in" $S '^hello from hamsh$'
expect "ls /bin" $S '^hamsh$'
expect "ls | wc counts the $NPROG programs" $S "^$NPROG $NPROG [0-9]+\$"
expect "ls | grep" $S '^halt$'
expect "a four-stage pipeline (four children beside the shell)" $S '^2 2 [0-9]+$'
expect "a built-in as the first stage of a pipeline" $S '^1 4 22$'
expect "> and >> to a file, read back" $S '^second line$'
expect "< from a file" $S '^2 4 23$'
expect "cp, mkdir, ls /tmp" $S '^copy$'
expect "head" $S '^first line$'
expect "arguments and exit status of a program" $S '^status was 3$'
expect "a binary file through a pipe" $S "^[0-9]+ [0-9]+ $(stat -c %s $T/user/hello)\$"
expect "unknown command" $S '^hamsh: command not found: no-such-command$'
expect "a faulting program is ended, the shell carries on" $S '^after the fault 139$'
expect "Ctrl-C ends a looping program" $S '^interrupted 130$'
expect "the FAT volume" $S '^PATTERN\.BIN$'
n40k="$(grep -c '^157 627 40000$' $S)"
[ "$n40k" = 2 ] && ok "cp card -> tmpfs -> card, 40000 bytes each way (tmpfs: 10 chunks of the Teensy's 4 KiB)" || bad "40000-byte copies counted $n40k times"
expect "script by source: started" $S '^script started$'
expect "script: for loop" $S '^script word beta$'
expect "script: arithmetic and if" $S '^script n is 42$'
expect "script: built-in into a pipe" $S '^1 2 13$'
if grep -q '^second shell status 0$' $S; then bad "a second shell started: the arena should not hold two"
else ok "a second shell does not fit and fails cleanly: '$(grep -m1 -iE 'memory|cannot|no space|ENOMEM|hamsh:.*/bin/hamsh' $S | head -c 100)' / $(grep -m1 '^second shell status' $S)"; fi
n12="$(grep -cE '^1 2 [78]$' $S)"
[ "$n12" = 12 ] && ok "a loop of 12 pipelines, 24 processes one after another (the shell's arenas and collector at the Teensy sizes)" || bad "the loop of 12 pipelines printed $n12 counts"
nmark="$(grep -c '^0 0 0$' $S)"
[ "$nmark" = "$m" ] && ok "all $m commands were answered" || bad "$nmark of $m commands answered"
echo "[t41mem] $fails failures"
exit $fails
