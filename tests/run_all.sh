#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# Hamnix Micro test runner (called by `make test` after the images are built).
#   1. compiler-side checks from the Adder tree (IR / disassembly, no emulator)
#   2. the Hamnix copies and the third-party C code are unmodified; C and
#      Adder only meet through extern "C" (tests/check_c_link.sh)
#   3. static checks on the linked images
#   4. run-time self-test (milestone 1: arithmetic, FPU, start-up) under QEMU
#   5. kernel tests under QEMU, with console input injected into the UART
#   6. an interactive monitor session, scripted
#   7. the fatal-fault report (deliberate undefined instruction before the
#      scheduler runs)
# Exit status is non-zero if anything fails.  Every check is counted: a check
# that does not run makes the count wrong, which is a failure.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ADDER="${ADDER:-../adder}"
QEMU="${QEMU:-qemu-system-arm}"
NM="${NM:-llvm-nm}"
OBJDUMP="${OBJDUMP:-llvm-objdump}"
SIZE="${SIZE:-llvm-size}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"
# The same runner serves a second QEMU board (tests/m4/run_all.sh sets
# these): the build directory, the machine, the first two hex digits of the
# 16 MB RAM (where the arenas are), and which sections to run.
B="${HMICRO_B:-build}"
MACHINE="${HMICRO_MACHINE:-mps2-an500}"
XP="${HMICRO_XP:-60}"
ONLY="${HMICRO_ONLY:-1 2 3 4 5 6 7 8}"
want() { case " $ONLY " in *" $1 "*) return 0;; esac; return 1; }
# An image ends its run by printing "[hmicro] exit status N" and requesting a
# system reset; -no-reboot turns the reset into the end of the emulator run.
# No semihosting: the guest has no channel to the host except its UART.
QFLAGS="-M $MACHINE -nographic -monitor none -serial stdio -no-reboot"
# Kernel tests run with QEMU's instruction counter as the clock (32 ns per
# instruction, idle time skipped): tick-exact timing checks then do not depend
# on how busy the host is.  The monitor session below runs in real time.
ICOUNT="-icount shift=5,sleep=off"
# The "card": a FAT32 image placed in the RAM disk before the kernel starts
# (the Makefile builds it with mtools).
SDCARD="-device loader,file=$B/sd.img,addr=0x20200000"
fails=0
ok()  { echo "[test] ok: $1"; }
bad() { echo "[test] FAIL: $1"; fails=$((fails+1)); }
expect() {  # expect <description> <file> <extended regex>
    if grep -Eq -- "$3" "$2"; then ok "$1"; else bad "$1 (no match for /$3/ in $2)"; fi
}

# Status of a finished run: 124 if QEMU had to be killed, otherwise the N of
# the image's last "[hmicro] exit status N" line, 125 if it printed none.
run_status() {  # run_status <logfile> <exit status of timeout/qemu>
    [ "$2" -eq 124 ] && return 124
    local n; n="$(tr -d '\r' < "$1" | sed -n 's/^\[hmicro\] exit status \([0-9]*\)$/\1/p' | tail -1)"
    [ -n "$n" ] || return 125
    return "$n"
}
run_qemu() {  # run_qemu <elf> <logfile>  -> status of the run (see run_status)
    timeout 60 "$QEMU" $QFLAGS -kernel "$1" </dev/null >"$2" 2>"$2.err"
    run_status "$2" $?
}

# Start QEMU with its serial input on a FIFO we can write to while watching
# its output.  qemu_start <elf> <logfile> [extra qemu flags]; then say/wait_for;
# qemu_wait returns the exit status.
qemu_start() {
    rm -f $B/uart.in; mkfifo $B/uart.in
    : > "$2"
    timeout 300 "$QEMU" $QFLAGS ${3:-} -kernel "$1" <$B/uart.in >"$2" 2>"$2.err" &
    QPID=$!
    exec 9>$B/uart.in
    QLOG="$2"
}
wait_for() {  # wait_for <fixed string> [occurrences]  (up to 60 s)
    local n="${2:-1}" i=0
    while [ "$(grep -cF -- "$1" "$QLOG" 2>/dev/null)" -lt "$n" ]; do
        i=$((i+1)); [ $i -gt 600 ] && return 1
        kill -0 $QPID 2>/dev/null || return 1
        sleep 0.1
    done
}
say() { printf "$1" >&9; }
qemu_wait() { local rc; wait $QPID; rc=$?; exec 9>&-; rm -f $B/uart.in; run_status "$QLOG" $rc; }

if want 1; then
echo "[test] === 1. compiler: thumbv7em target ($ADDER/scripts/test_llvm_thumbv7em.sh)"
if bash "$ADDER/scripts/test_llvm_thumbv7em.sh" > $B/compiler_test.log 2>&1; then
    ok "compiler regression test ($(grep -c '   ok:' $B/compiler_test.log) assertions)"
else
    bad "compiler regression test (see $B/compiler_test.log)"; grep -v '   ok:' $B/compiler_test.log
fi

fi
if want 2; then
echo "[test] === 2. files copied from Hamnix are unmodified, or differ only by a recorded patch (fs/HAMNIX_ORIGIN)"
ncopies=0; npatched=0
while read -r sum path; do
    case "$sum" in \#*|"") continue;; esac
    ncopies=$((ncopies+1))
    head -1 "$path" | grep -q '^# Hamnix Micro: copied from Hamnix' || { bad "$path has no origin header"; continue; }
    if [ -f "$path.patch" ]; then
        # the copy minus its header, with the recorded patch taken out again,
        # must be the Hamnix original
        npatched=$((npatched+1))
        tail -n +4 "$path" > $B/origin_check.tmp
        have="$(patch -R -s -o - $B/origin_check.tmp "$path.patch" 2>/dev/null | sha256sum | cut -d' ' -f1)"
        nlines="$(grep -c '^[-+][^-+]' "$path.patch")"
        [ "$have" = "$sum" ] && ok "$path is its Hamnix original plus $path.patch ($nlines changed lines)" \
            || bad "$path is not its Hamnix original plus $path.patch"
    else
        have="$(tail -n +4 "$path" | sha256sum | cut -d' ' -f1)"
        [ "$have" = "$sum" ] && ok "$path matches its Hamnix original" || bad "$path differs from the recorded Hamnix original"
    fi
done < fs/HAMNIX_ORIGIN
[ "$ncopies" -ge 4 ] && ok "$ncopies copied files listed, $npatched of them with a patch file" || bad "$ncopies copied files listed, expected at least 4"

echo "[test] === 2b. third-party C code is unmodified, and C and Adder only meet through extern \"C\""
nthird=0
while read -r sum name; do
    [ ${#sum} = 64 ] || continue
    nthird=$((nthird+1))
    have="$(sha256sum < "third_party/sensirion-sht4x/$name" | cut -d' ' -f1)"
    [ "$have" = "$sum" ] || bad "third_party/sensirion-sht4x/$name differs from the recorded upstream file"
done < third_party/sensirion-sht4x/UPSTREAM
[ "$nthird" = 9 ] && ok "9 Sensirion files match the hashes in UPSTREAM" || bad "$nthird Sensirion files listed in UPSTREAM, expected 9"
KO="$B/startup.o $B/aeabi.o $B/cpu.o $B/switch.o $B/fptest.o"
if bash tests/check_c_link.sh $B/ktest.ll $B/ktest.o $KO -- $B/c/*.o > $B/clink.log 2>&1; then
    ok "link rule: $(sed 's/^ok: //' $B/clink.log)"
else
    bad "link rule violated"; cat $B/clink.log
fi
# the rule must catch a C object that uses bare libc names or kernel functions
"${CLANG:-clang}" --target=thumbv7em-none-eabihf -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -ffreestanding -fno-builtin -O1 \
    -c tests/c/bad_libc.c -o $B/c_bad.o 2>$B/c_bad.err || bad "cannot compile tests/c/bad_libc.c"
bash tests/check_c_link.sh $B/ktest.ll $B/ktest.o $KO -- $B/c/*.o $B/c_bad.o > $B/clink_bad.log 2>&1; rc=$?
[ $rc -ne 0 ] && ok "link rule rejects a bad C object" || bad "link rule accepted tests/c/bad_libc.c"
expect "  ... C calling the Adder-convention memcpy" $B/clink_bad.log "^R1: C code calls 'memcpy'"
expect "  ... C calling an Adder kernel function" $B/clink_bad.log "^R1: C code calls 'kmalloc'"
expect "  ... C defining a bare C library name" $B/clink_bad.log "^R3: .*'strlen'"

rm -f $B/*.bin
fi
if want 3; then
echo "[test] === 3. static checks on the images"
for img in hmicro monitor ktest selftest; do
    undef="$("$NM" -u $B/$img.elf | wc -l)"
    [ "$undef" = 0 ] && ok "$img: no undefined symbols" || bad "$img: $undef undefined symbols"
done
sym() { "$NM" $B/$1.elf | awk -v s="$2" '$3==s{print $1}'; }
word() {  # word <img> <address>: little-endian word of the flash image at that address
    [ -f $B/$1.bin ] || "$OBJCOPY" -O binary -j .boot -j .text $B/$1.elf $B/$1.bin
    od -An -tx4 -j $(($2)) -N 4 $B/$1.bin | tr -d ' '
}
[ "$(sym hmicro hmicro_boot_vectors)" = "00000000" ] && ok "boot vectors at 0x00000000" || bad "boot vectors at $(sym hmicro hmicro_boot_vectors)"
[ "$(sym hmicro hmicro_vectors)" = "00001000" ] && ok "vector table at 0x00001000, behind the null guard" || bad "vector table at $(sym hmicro hmicro_vectors)"
[ "$(word hmicro 0)" = "$(sym hmicro __stack_top)" ] && ok "word 0 is the initial stack pointer (0x$(word hmicro 0))" || bad "word 0 is $(word hmicro 0)"
[ "$((0x$(word hmicro 4)))" = "$((0x$(sym hmicro Reset_Handler) + 1))" ] && ok "word 4 is Reset_Handler with the Thumb bit" || bad "word 4 is $(word hmicro 4)"
[ "$(word hmicro 0x20)" = "00000000" ] && [ "$(word hmicro 0xffc)" = "00000000" ] && ok "nothing else lives in the first 4 KB" || bad "the null-guard area is not empty"
for v in "11:svc_handler" "14:pendsv_handler" "15:systick_handler" "16:uart0_rx_handler"; do
    n="${v%%:*}"; s="${v#*:}"
    [ "$((0x$(word hmicro $((0x1000 + n*4)))))" = "$((0x$(sym hmicro $s) + 1))" ] && ok "vector $n is $s" || bad "vector $n is $(word hmicro $((0x1000 + n*4))), $s is $(sym hmicro $s)"
done
fp="$(grep -cE 'v(mul|div|add|sub)\.f64' $B/selftest.lst)"
[ "$fp" -gt 20 ] && ok "self-test uses double-precision FPU instructions ($fp)" || bad "only $fp f64 FPU instructions"
soft="$(cat $B/hmicro.lst $B/ktest.lst $B/selftest.lst | grep -cE '__aeabi_d(add|sub|mul|div)|__adddf3|__muldf3')"
[ "$soft" = 0 ] && ok "no soft-float arithmetic calls" || bad "$soft soft-float calls"
vol="$(awk '/^define .*@test_volatile_mmio\(/{f=1} f&&/(load|store) volatile i32/{n++} /^}/{f=0} END{print n+0}' $B/selftest.ll)"
[ "$vol" = 7 ] && ok "test_volatile_mmio: 5 volatile loads + 2 volatile stores of CTRL in the IR" || bad "test_volatile_mmio has $vol volatile accesses, want 7"
dsz="$("$SIZE" -A $B/hmicro.elf | awk '$1==".data"{print $2}')"
nstr="$(grep -c '^@\.Lstr.* = internal constant' $B/hmicro.ll)"; nstrw="$(grep -c '^@\.Lstr.* = internal global' $B/hmicro.ll)"
[ "$nstrw" = 0 ] && [ "$nstr" -gt 100 ] && [ "$dsz" -lt 4096 ] && ok "string literals are constants ($nstr of them; .data is $dsz bytes)" || bad "string literals: $nstr constant, $nstrw writable, .data $dsz bytes"
tb="$("$SIZE" -A $B/hmicro.elf | awk '$1==".xbss"{print $3}')"
[ "$((tb))" = "$((0x60000000))" ] && ok "the large file-system table is placed in the 16 MB region" || bad ".xbss at $tb"
nv="$(grep -c '^define void @' $B/hmicro.ll)"
[ "$nv" -gt 50 ] && ok "result-less functions are emitted as void ($nv of them)" || bad "only $nv void functions"

fi
if want 4; then
echo "[test] === 4. run-time self-test under QEMU (milestone 1 checks)"
EXPECTED_SELF="$(grep -cE '^ +check\(' demo/main.ad)"
run_qemu $B/selftest.elf $B/selftest.out; rc=$?
cat $B/selftest.out
[ $rc -eq 0 ] && ok "exit status 0" || bad "exit status $rc (124 = timed out)"
nfail="$(grep -c '^FAIL ' $B/selftest.out)"; npass="$(grep -c '^PASS ' $B/selftest.out)"
[ "$nfail" = 0 ] && ok "no FAIL lines" || bad "$nfail FAIL lines"
[ "$npass" = "$EXPECTED_SELF" ] && ok "$npass PASS lines (all $EXPECTED_SELF checks ran)" || bad "$npass PASS lines, expected $EXPECTED_SELF"
expect "RESULT: PASS" $B/selftest.out '^RESULT: PASS'

fi
if want 5; then
echo "[test] === 5. kernel tests under QEMU (threads, sync, system calls, MPU, heap, files, C code, processes, pipes, console)"
EXPECTED_K="$(grep -cE '^ +check\(' tests/ktest_main.ad)"
rm -rf $B/panel-ktest $B/panel-ktest.bin; mkdir -p $B/panel-ktest
# the second UART is the fake e-paper panel's output (drivers/display/fakepanel.ad)
qemu_start $B/ktest.elf $B/ktest.out "$ICOUNT $SDCARD -serial file:$B/panel-ktest.bin"
if wait_for "-- 9. console"; then
    # typed "by hand": a line, corrections with DEL and backspace, a line
    # killed with Ctrl-U, a line read in two pieces, Ctrl-D
    for keys in 'status report\r' 'backspacx\x7fe wot\x08rks\r' 'first try\x15second try\r' 'long line\r' '\x04'; do
        say "$keys"; sleep 0.2
    done
else
    bad "the kernel tests never reached the console group"
fi
qemu_wait; rc=$?
tr -d '\r' < $B/ktest.out > $B/ktest.txt
cat $B/ktest.txt
[ $rc -eq 0 ] && ok "exit status 0" || bad "exit status $rc (124 = timed out; otherwise the number of failed checks)"
nfail="$(grep -c '^FAIL ' $B/ktest.txt)"; npass="$(grep -c '^PASS ' $B/ktest.txt)"
[ "$nfail" = 0 ] && ok "no FAIL lines" || bad "$nfail FAIL lines"
[ "$npass" = "$EXPECTED_K" ] && ok "$npass PASS lines (all $EXPECTED_K checks ran)" || bad "$npass PASS lines, expected $EXPECTED_K"
expect "RESULT: PASS" $B/ktest.txt '^RESULT: PASS'
# the fault reports must name the thread
expect "stack overflow reported with the thread's name (user)" $B/ktest.txt "thread [0-9]+ 'deep-user' ended: stack overflow at 0x${XP}f"
expect "stack overflow reported with the thread's name (kernel thread)" $B/ktest.txt "thread [0-9]+ 'deep-kern' ended: stack overflow at 0x${XP}[0-3]"
expect "kernel-memory access reported with the thread's name" $B/ktest.txt "thread [0-9]+ 'peek' ended: unprivileged access violation at 0x20"
expect "null pointer reported at address 0" $B/ktest.txt "'null-user' ended: unprivileged access violation at 0x00000000"
expect "console echo: the typed line came back" $B/ktest.txt '^status report$'
expect "console echo: Ctrl-U rubbed the line out" $B/ktest.txt 'first try.*second try'
cyc="$(sed -n 's/^BENCH yield ping-pong: \([0-9]*\) context switches in \([0-9]*\) timer cycles.*/\1 \2/p' $B/ktest.txt)"
if [ -n "$cyc" ]; then
    set -- $cyc
    # 40 ns per timer cycle, 32 ns per instruction under -icount shift=5
    echo "[test] info: $(( $2 * 40 / 32 / $1 )) instructions per voluntary context switch ($1 switches, yield call included)"
    ok "context-switch benchmark ran"
else
    bad "no benchmark line"
fi
cyc="$(sed -n 's/^BENCH system call: \([0-9]*\) calls in \([0-9]*\) timer cycles (thread start and exit alone: \([0-9]*\)).*/\1 \2 \3/p' $B/ktest.txt)"
if [ -n "$cyc" ]; then
    set -- $cyc
    echo "[test] info: $(( ($2 - $3) * 40 / 32 / $1 )) instructions per system-call round trip (gettid from an unprivileged thread, $1 calls)"
    ok "system-call benchmark ran"
else
    bad "no system-call benchmark line"
fi

# process figures (instructions = timer cycles * 40 / 32, as above)
bench() { sed -n "s/^BENCH $1: .* in \([0-9]*\) timer cycles.*/\1/p" $B/ktest.txt; }
c_spawn="$(bench spawn)"; c_rfork="$(bench rfork)"; c_pipe="$(bench pipe)"
c_hamsh="$(sed -n 's/^BENCH hamsh: .*collect: \([0-9]*\) timer cycles.*/\1/p' $B/ktest.txt)"
if [ -n "$c_spawn" ] && [ -n "$c_rfork" ] && [ -n "$c_pipe" ] && [ -n "$c_hamsh" ]; then
    i_spawn=$(( c_spawn * 40 / 32 / 20 ))
    echo "[test] info: $i_spawn instructions per spawn + exit + wait of /bin/ptest ($(stat -c %s $B/user/ptest)-byte file)"
    echo "[test] info: $(( (c_rfork * 40 / 32 - i_spawn) / 20 )) instructions per rfork + exec + exit + wait of the same program"
    echo "[test] info: $(( c_hamsh * 40 / 32 )) instructions to start /bin/hamsh ($(stat -c %s $B/user/hamsh)-byte file), run an empty script and collect it"
    echo "[test] info: pipe: $(( (c_pipe * 40 / 32 - 2 * i_spawn) * 100 / 1048576 )) instructions per 100 bytes, process to process (1 MiB in 4 KiB writes and reads)"
    ok "process benchmarks ran"
else
    bad "process benchmark lines missing"
fi
expect "tmpfs per-file cost reported" $B/ktest.txt '^BENCH tmpfs: an empty file takes 0 bytes of kernel heap, its first byte [0-9]+ more'
expect "a faulting process is reported as a process, by name" $B/ktest.txt "process [0-9]+ 'ptest' ended: stack overflow at 0x$XP"
expect "a breakpoint instruction in a process is reported, the system carries on" $B/ktest.txt "process [0-9]+ 'ptest' ended: breakpoint instruction or escalated fault"
expect "the loaded C program printed through its relocated pointers" $B/ktest.txt '^crel: relocated pointers ok$'

# What the fake panel received, as images (tests/display/panel2png.py), and
# the text on the last one read back from its pixels with the font.
FONT=third_party/font8x8/font8x8_basic.h
have="$(sha256sum < $FONT | cut -d' ' -f1)"
[ "$have" = "$(awk '$2=="font8x8_basic.h"{print $1}' third_party/font8x8/UPSTREAM)" ] && ok "third_party/font8x8/font8x8_basic.h matches the hash in UPSTREAM" || bad "third_party/font8x8/font8x8_basic.h differs from the recorded upstream file"
P=$B/panel-ktest.txt
python3 -I tests/display/panel2png.py $B/panel-ktest.bin $B/panel-ktest --font $FONT --yscale 2 --keep 3 > $P 2>&1; prc=$?
tail -36 $P
[ $prc -eq 0 ] && ok "display: the fake panel's stream is well-formed, every record's checksum holds, every PNG reads back as written" || bad "display: panel2png.py failed ($prc)"
nrec="$(sed -n 's/^   fake panel: \([0-9]*\) records.*/\1/p' $B/ktest.txt)"
[ -n "$nrec" ] && [ "$(grep -c '^#[0-9]* [FPS] ' $P)" = "$nrec" ] && ok "display: the host received all $nrec records the kernel says it sent" || bad "display: the kernel sent '$nrec' records, the host found $(grep -c '^#[0-9]* [FPS] ' $P)"
expect "display: the 2-bit frame holds all four grey levels" $P '^#0 F 2 0 0 400 300 sum ok levels 0,1,2,3$'
expect "display: the partial refresh of a 30-pixel change was a 40 x 10 window at x = 8" $P '^#[0-9]+ P 1 8 40 40 10 sum ok$'
expect "display: the panel was put to sleep last" $P '^#[0-9]+ S 1 0 0 0 0 sum ok$'
txt() { awk '/^text:$/{f=1; next} f' $P | sed -n "$1p"; }
[ "$(txt 1)" = "Hamnix Micro display test" ] && [ "$(txt 2)" = "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ" ] \
    && [ "$(txt 3)" = 'abcdefghijklmnopqrstuvwxyz !"#$%&'"'"'()*+,-./:;<=>?@[]^_`{|}~' ] \
    && ok "display: the last frame's pixels read back as the text that was written (95 printable characters)" \
    || bad "display: text read back from the last frame: '$(txt 1)' / '$(txt 2)' / '$(txt 3)'"
[ "$(txt 6)" = "          placed at row 6, column 11" ] && [ "$(txt 8)" = "plain inverse plain" ] && [ "$(txt 30 | sed 's/^ *//')" = "end" ] && [ "$(txt 30 | wc -c)" = 93 ] \
    && ok "display: cursor addressing, an inverse word and the last cell row (row 30, column 90) are where they belong in the image" \
    || bad "display: rows 6, 8, 30 read back as '$(txt 6)' / '$(txt 8)' / '$(txt 30)'"
fi
if want 6; then
echo "[test] === 6. monitor session over the UART (real-time clock, commands typed by the harness)"
qemu_start $B/monitor.elf $B/monitor.out
p=0
cmd() {  # send one command line and wait for the next prompt
    p=$((p+1))
    wait_for "hmicro> " $p || { bad "no prompt #$p from the monitor"; return 1; }
    say "$1\\r"
}
cmd 'help'
cmd 'ps'
cmd 'heap'
cmd 'mkdir /tmp/d'
cmd 'write /tmp/d/hello.txt Hello,  Hamnix Micro!'
cmd 'append /tmp/d/hello.txt second lime\x7f\x7f\x7fine'
cmd 'ls /'
cmd 'ls /tmp/d'
cmd 'cat /tmp/d/hello.txt'
cmd 'stat /tmp/d/hello.txt'
cmd 'cd /tmp/d'
cmd 'pwd'
cmd 'mv hello.txt ../moved.txt'
cmd 'ls /tmp'
cmd 'cat /nope'
cmd 'ls /dev'
cmd 'fault stack'
cmd 'fault kread'
cmd 'fault null'
cmd 'fault udf'
cmd 'rm /tmp/moved.txt'
cmd 'cd /'
cmd 'rm /tmp/d'
cmd 'ls /tmp'
cmd 'ps'
cmd 'heap'
cmd 'info'
cmd 'bogus'
cmd 'halt 0'
qemu_wait; rc=$?
tr -d '\r' < $B/monitor.out > $B/monitor.txt
cat $B/monitor.txt
M=$B/monitor.txt
[ $rc -eq 0 ] && ok "monitor: 'halt 0' ended the run with status 0" || bad "monitor: exit status $rc"
expect "monitor: banner" $M '^Hamnix Micro 0\.2 \(milestone 2\)'
expect "monitor: 29 prompts" $M 'hmicro> halt 0'
expect "monitor: help lists the commands" $M '^  ps +threads: state'
expect "monitor: ps lists the idle thread" $M '^ +1 idle +ready +7 kern +[0-9]+/ +[0-9]+ +- +[0-9]+ +[0-9]+$'
expect "monitor: ps shows itself running with its stack high-water mark" $M '^ +3 monitor +running +2 kern +[0-9]+/ 15360 '
expect "monitor: heap statistics, consistent" $M '^kernel heap: total [0-9]+  used [0-9]+  peak [0-9]+  free [0-9]+ in [0-9]+ block'
expect "monitor: heap consistency check is 0" $M 'requested bytes live [0-9]+  consistency 0$'
expect "monitor: write reports the byte count" $M '^wrote 16 bytes to /tmp/d/hello.txt$'
expect "monitor: ls / shows dev, tmp and etc" $M '^dev$'
expect "monitor: ls shows the new file" $M '^hello.txt$'
expect "monitor: cat prints the first line" $M '^Hello,  Hamnix Micro!$'
expect "monitor: cat prints the appended line, edited with DEL on the way in" $M '^second line$'
expect "monitor: stat" $M '^/tmp/d/hello.txt: file, 28 bytes, mode 1a4, mtime [0-9]+$'
expect "monitor: pwd after cd" $M '^/tmp/d$'
expect "monitor: mv with relative paths" $M '^moved.txt$'
expect "monitor: error with the kernel's error string" $M '^cat: error -2 \(file does not exist\)$'
expect "monitor: /dev lists the console" $M '^console$'
expect "monitor: stack-overflow fault names the thread" $M "thread [0-9]+ 'stack' ended: stack overflow at 0x60"
expect "monitor: the system carries on after it" $M "^thread 'stack' exited with code 139; the system carries on$"
expect "monitor: kernel read fault" $M "'kread' ended: unprivileged access violation at 0x20"
expect "monitor: null pointer fault" $M "'null' ended: unprivileged access violation at 0x00000000"
expect "monitor: undefined instruction" $M "^thread 'udf' exited with code 132"
expect "monitor: counters" $M '^system calls [0-9]+  thread faults 4  console bytes in [0-9]+  open files 1$'
expect "monitor: unknown command" $M '^unknown or incomplete command: bogus'
nd="$(grep -c '^d$' $M)"; [ "$nd" = 1 ] && ok "monitor: /tmp/d listed once, gone after rm" || bad "monitor: /tmp/d listed $nd times"

fi
if want 7; then
echo "[test] === 7. fatal-fault report under QEMU (undefined instruction before the scheduler runs)"
run_qemu $B/faulttest.elf $B/faulttest.out; rc=$?
cat $B/faulttest.out
[ $rc -eq 3 ] && ok "exit status 3 (fault handler ended the run)" || bad "exit status $rc, want 3"
expect "reported as UsageFault" $B/faulttest.out 'Hamnix Micro FAULT: UsageFault \(exception 6\)'
expect "CFSR = 0x00010000 (UFSR.UNDEFINSTR)" $B/faulttest.out 'CFSR  = 0x00010000'
expect "UNDEFINSTR decoded" $B/faulttest.out 'UFSR.UNDEFINSTR'
udf="$(awk '/\tudf\t/{sub(":","",$1); print $1; exit}' $B/faulttest.lst)"
pc="$(tr -d '\r' < $B/faulttest.out | awk '$1=="pc"{print $3}')"
[ -n "$udf" ] && [ "$((pc))" = "$((0x$udf))" ] && ok "stacked pc ($pc) is the address of the udf instruction" \
    || bad "stacked pc '$pc' vs udf at '$udf'"
grep -q 'continued past udf' $B/faulttest.out && bad "execution continued past the fault" || ok "execution did not continue past the fault"

fi
if want 8; then
echo "[test] === 8. the shell: Hamnix's hamsh as a process on the UART console, running programs from /bin"
# The session is typed into the emulated UART like the monitor session above.
# hamsh redraws its prompt line at every keystroke, so prompts cannot be
# counted; instead every command is followed by `wc < /dev/null`, whose output
# "0 0 0" is never part of what was typed, and the harness waits for the n-th
# one before it types the next command.
rm -rf $B/panel-shell $B/panel-shell.bin; mkdir -p $B/panel-shell
qemu_start $B/hmicro.elf $B/shell.out "$SDCARD -serial file:$B/panel-shell.bin"
m=0
sh() {  # type one command line, then the marker command; wait for the marker
    m=$((m+1))
    say "$1\\r"; say 'wc < /dev/null\r'
    wait_for "0 0 0" $m || { bad "shell: no answer to command #$m ($1)"; return 1; }
}
shn() { say "$1\\r"; }  # type a command line without the marker (it reads no input, so the next line may be typed ahead)
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
    sh 'cat /tmp/note'
    sh 'head -1 < /tmp/copy'
    shn '/bin/hello with two'      # no marker: the next line reads its status
    sh 'echo status was $status'
    sh 'cat /bin/hello | wc'
    sh 'no-such-command'
    sh 'ls /nowhere 2> /tmp/err'
    sh 'cat /tmp/err'
    shn 'ptest peek 20000000'
    sh 'echo after the fault $status'
    # Ctrl-C: a program that loops for ever, then one that waits for input
    shn 'ptest loop'; sleep 1; say '\x03'
    sh 'echo interrupted $status'
    shn 'cat'; sleep 0.5; say 'typed to cat\r'; sleep 0.5; say '\x03'
    sh 'echo again $status'
    # the card
    sh 'ls /sd'
    sh 'cat /sd/README.TXT'
    sh 'cp /sd/PATTERN.BIN /tmp/pattern'
    sh 'cat /tmp/pattern | wc'
    sh 'cp /tmp/pattern /sd/BACK.BIN'
    sh 'cat /sd/BACK.BIN | wc'
    shn '/sd/DOCS/HELLO card'
    sh 'echo from the card $status'
    sh 'rm /sd/BACK.BIN'
    sh 'cat /sd/BACK.BIN'
    # a script file, written with the shell itself, run by a second hamsh
    sh "echo 'echo script started' > /tmp/s.hsh"
    sh "echo 'ls /bin | wc > /tmp/count' >> /tmp/s.hsh"
    sh "echo 'cat /tmp/count' >> /tmp/s.hsh"
    sh "echo 'n = 6 * 7' >> /tmp/s.hsh"
    sh "echo 'for w in [\"alpha\", \"beta\"] { echo script word \$w }' >> /tmp/s.hsh"
    sh "echo 'if n == 42 { echo script n is \$n }' >> /tmp/s.hsh"
    sh "echo 'echo script piped | wc' >> /tmp/s.hsh"
    sh "echo 'exit 5' >> /tmp/s.hsh"
    shn 'hamsh /tmp/s.hsh'
    sh 'echo script status $status'
    # ---- milestone 4: the rest of the shell, and more programs ----
    # a background job, `jobs`, and `kill PID` (a note written to /proc/PID/note)
    sh 'ptest loop &'
    sh 'jobs'
    bgpid="$(tr -d '\r' < $QLOG | sed -n 's/^\[1\] \([0-9][0-9]*\)$/\1/p' | tail -1)"
    sh 'ps'
    sh "kill ${bgpid:-0}"
    sleep 0.5
    sh 'echo job-ended-check'
    sh 'cat /proc/tasks > /tmp/tasks'
    sh 'grep -c ptest < /tmp/tasks'
    # two streams into one file
    sh 'ptest outerr > /tmp/both 2>&1'
    sh 'cat /tmp/both'
    sh 'wc < /tmp/both'
    # a function
    sh 'def greet(name) { echo hello $name from a function }'
    sh 'greet("world")'
    # history: up-arrow twice skips the marker command and recalls the line
    sh 'echo history-probe'
    say '\x1b[A\x1b[A\r'; sh 'echo after-history'
    # completion: a command name, then a path
    say 'ec\tcompleted-command\r'; sh 'echo after-completion'
    say 'cat /tmp/bo\t | wc\r'; sh 'echo after-path-completion'
    # Ctrl-C ends a whole pipeline, though the shell names no group for one
    shn 'ptest loop | cat | wc'; sleep 1; say '\x03'
    sh 'echo pipeline interrupted $status'
    sh 'cat /proc/tasks > /tmp/tasks2'
    sh 'grep -c ptest < /tmp/tasks2'
    # there are no here-documents in this hamsh: `cat << EOF` is cat on the console
    shn 'cat << EOF'; sleep 0.5; say 'not a here-document\r'; sleep 0.3; say '\x03'
    sh 'echo no-heredoc $status'
    # programs copied from Hamnix
    sh 'seq 5 > /tmp/n'
    sh 'cat /tmp/n | sort -r | head -2'
    sh 'echo pear > /tmp/u'
    sh 'echo pear >> /tmp/u'
    sh 'echo apple >> /tmp/u'
    sh 'sort < /tmp/u | uniq -c'
    sh 'echo Shout | tr a-z A-Z'
    sh 'echo abc | od'
    sh 'tail -2 < /tmp/n'
    sh 'echo left:mid:right > /tmp/c'
    sh 'cut -d ":" -f 2 < /tmp/c'
    sh 'echo through-tee | tee /tmp/teeout | wc'
    sh 'cat /tmp/teeout'
    sh 'mv /tmp/u /tmp/moved-u'
    sh 'touch /tmp/touched'
    sh 'ls /tmp'
    sh 'free'
    sh 'df'
    shn 'date'
    sh 'echo date-unset $status'
    sh 'setdate 1795780800'
    sh 'date'
    sh 'sleep 2'
    sh 'cat /proc/uptime'
    # the keyboard: text typed on the emulated key matrix (TCA8418 model ->
    # I2C -> driver -> key map -> console) instead of the UART
    shn 'keypress -n echo Typed On The Matrix 2026 x_y'; sleep 1.5    # nothing else is typed meanwhile
    sh 'echo after-keypress'
    # the editor: Hamnix's vi, driven by scripted keystrokes.  Insert three
    # lines (one corrected with DEL), write, delete the first line (dd), open
    # a line above (O), delete two characters at the end of the last line
    # (G $ x x), open a line below (o), write and quit (:wq).  Then again:
    # change something and leave without saving (:q is refused, :q! is not).
    shn 'vi /tmp/edit.txt'; sleep 0.8
    say 'ifirst line\rsecond lime\x7fne\rthird\x1b'; sleep 0.3
    say ':w\r'; sleep 0.3
    say 'ggdd'; sleep 0.2
    say 'Otop\x1b'; sleep 0.2
    say 'G$xx'; sleep 0.2
    say 'oappended via o\x1b'; sleep 0.2
    say ':wq\r'; sleep 0.5
    sh 'echo vi-status $status'
    sh 'wc < /tmp/edit.txt'
    sh 'cat /tmp/edit.txt'
    shn 'vi /tmp/edit.txt'; sleep 0.8
    say 'ddixyz\x1b'; sleep 0.2
    say ':q\r'; sleep 0.3
    say ':q!\r'; sleep 0.5
    sh 'wc < /tmp/edit.txt'
    # ---- milestone 5: namespaces ----
    sh 'mkdir /tmp/ua'; sh 'mkdir /tmp/ub'; sh 'mkdir /tmp/uc'; sh 'mkdir /tmp/un'
    sh 'echo from-a > /tmp/ua/shared'; sh 'echo only-a > /tmp/ua/afile'
    sh 'echo from-b > /tmp/ub/shared'; sh 'echo only-b > /tmp/ub/bfile'
    sh 'cat /proc/self/ns | wc'
    # `ns { }` is rfork(RFPROC|RFNAMEG): a bind made in the child ...
    sh 'ns { bind /tmp/ua /tmp/un ; cat /tmp/un/afile ; cat /proc/self/ns | wc }'
    # ... is not the parent's
    sh 'cat /tmp/un/afile'
    sh 'cat /proc/self/ns | wc'
    # a union of two directories: order, merged listing, where a create goes
    sh 'bind /tmp/ua /tmp/un'
    sh 'bind -a /tmp/ub /tmp/un'
    sh 'ls /tmp/un'
    sh 'ls /tmp/un | wc'
    sh 'cat /tmp/un/shared'
    sh 'cat /tmp/un/bfile'
    sh 'echo made-here > /tmp/un/created'
    sh 'ls /tmp/ua | wc'
    sh 'bind -bc /tmp/uc /tmp/un'
    sh 'echo in-c > /tmp/un/cfile'
    sh 'ls /tmp/uc'
    sh 'cat /proc/self/ns'
    # the text of /proc/self/ns, run in an empty namespace, builds the same one
    sh 'cat /proc/self/ns > /tmp/ns.saved'
    sh "echo 'ns clean {' > /tmp/replay.hsh"
    sh 'cat /tmp/ns.saved >> /tmp/replay.hsh'
    sh "echo 'cat /proc/self/ns > /tmp/ns.replayed' >> /tmp/replay.hsh"
    sh "echo '}' >> /tmp/replay.hsh"
    sh "echo 'exit 0' >> /tmp/replay.hsh"
    shn 'hamsh /tmp/replay.hsh'
    sh 'echo replay-status $status'
    sh 'echo saved-ns-follows'; sh 'cat /tmp/ns.saved'
    sh 'echo replayed-ns-follows'; sh 'cat /tmp/ns.replayed'
    sh 'echo ns-texts-end'
    # another process has its own: a job started before a bind does not get it
    sh 'ptest loop &'
    nspid="$(tr -d '\r' < $QLOG | sed -n 's/^\[[0-9]*\] \([0-9][0-9]*\)$/\1/p' | tail -1)"
    sh 'bind /tmp/ub /tmp/late'
    sh "cat /proc/${nspid:-0}/ns | grep /tmp | wc"
    sh 'cat /proc/self/ns | grep /tmp | wc'
    sh "kill ${nspid:-0}"
    sleep 0.5
    sh 'unmount /tmp/late'
    sh 'unmount /tmp/un'
    sh 'cat /tmp/un/shared'
    # bind over /bin replaces a program for one process only
    sh 'mkdir /tmp/mybin'
    sh 'cp /bin/hello /tmp/mybin/seq'
    sh 'ns { bind -b /tmp/mybin /bin ; seq 7 }'
    sh 'seq 7 | tail -1'
    # a namespace built from nothing (a template, entered later)
    sh "box = ns clean { bind '#t/tmp/ua' / ; bind '#r' /bin }"
    sh 'enter box { ls / | wc }'
    sh 'enter box { cat /tmp/copy }'
    # `with bind` in the shell itself, undone at the closing brace
    sh 'with bind("/tmp/ub", "/tmp/un") as p { cat /tmp/un/bfile | tr a-z A-Z }'
    sh 'cat /tmp/un/bfile'
    sh 'bind /nonexistent /tmp/un'
    # ---- milestone 5: drivers as files.  tests/scripts/devices.hsh, typed
    # into a file and run by a second shell, drives the emulated sensor, the
    # I2C bus and the GPIO pins with echo and cat
    while IFS= read -r line; do
        case "$line" in \#*|"") continue;; esac
        sh "echo '$line' >> /tmp/dev.hsh"
    done < tests/scripts/devices.hsh
    shn 'hamsh /tmp/dev.hsh'
    sh 'echo devices-script $status'
    sh 'echo Shown-On-Panel > /dev/screen/text'
    sh 'cat /dev/screen/text | grep "^Shown"'
    sh 'cat /dev/screen/data | wc'
    shn 'echo echo Typed-Via-Dev-Keys > /dev/keys'; sleep 1.5
    sh 'echo after-dev-keys'
    sh 'ls /dev | wc'
    # power: how often the processor wakes while the system idles at the
    # prompt of a sleeping command, tickless and with the periodic tick;
    # then suspend, ended by a key and by its timer
    sh 'idlestat 3'
    sh 'idlestat 3 -p'
    shn 'suspend 30'; sleep 1.5; say '\r'
    sh 'echo after-suspend'
    sh 'suspend 2 -n'
    # history survives the shell: exit, init starts another, up-arrow recalls
    sh 'echo persistent-history-probe'
    say 'exit\r'
    wait_for "starting another" || bad "init did not start another shell after exit"
    wait_for "hamsh\$ " 2 || bad "no prompt from the second shell"
    sleep 0.5
    say '\x1b[A\x1b[A\x1b[A\r'; sh 'echo after-reload'
    # a pasted block: 60 command lines in one write, more than the console's
    # input ring would hold if the sender were not held off
    paste=""; for i in $(seq -w 1 60); do paste="${paste}echo paste line x$i >> /tmp/paste\\r"; done
    say "$paste"
    sh 'wc < /tmp/paste'
    say 'halt 0\r'
else
    bad "the shell never printed its prompt"
fi
qemu_wait; rc=$?
# what the console showed: the line editor rewrites a line with CR, so keep
# what follows the last one, and drop the escape sequences
sed 's/\r*$//; s/.*\r//; s/\x1b\[[0-9;?]*[A-Za-z]//g' < $B/shell.out > $B/shell.txt
cat $B/shell.txt
S=$B/shell.txt
NPROG="$(echo $(grep -c . <<< "$(ls $B/user | grep -v '\.')"))"
[ $rc -eq 0 ] && ok "shell: 'halt 0' ended the run with status 0" || bad "shell: exit status $rc"
expect "shell: banner of the system image" $S '^Hamnix Micro 0\.[0-9]+ \(milestone [0-9]+\)'
expect "shell: hamsh's own banner (it is running as a process)" $S "^hamsh . Hamnix shell"
expect "shell: a built-in" $S '^hello from hamsh$'
expect "shell: ls /bin lists the programs (an external command found through PATH)" $S '^hamsh$'
expect "shell: ls | wc counts the $NPROG programs" $S "^$NPROG $NPROG [0-9]+\$"
expect "shell: ls | grep" $S '^halt$'
expect "shell: a four-stage pipeline" $S '^2 2 [0-9]+$'
expect "shell: a built-in as the first stage of a pipeline" $S '^1 4 22$'
expect "shell: > and >> to a file, read back with cat" $S '^second line$'
expect "shell: < from a file" $S '^2 4 23$'
nsec="$(grep -c '^second line$' $S)"
[ "$nsec" = 2 ] && ok "shell: pipeline into a redirection (cat | grep > file), read back" || bad "shell: 'second line' seen $nsec times, expected 2"
expect "shell: cp, mkdir, ls /tmp" $S '^copy$'
expect "shell: mkdir" $S '^dir$'
expect "shell: rm, then cat fails with the kernel's error string" $S '^cat: cannot open /tmp/note: .*file does not exist'
expect "shell: head" $S '^first line$'
expect "shell: arguments reach a program" $S '^  arg: two$'
expect "shell: the exit status of a program (argc = 3)" $S '^status was 3$'
expect "shell: a binary file through a pipe, byte count intact" $S "^[0-9]+ [0-9]+ $(stat -c %s $B/user/hello)\$"
expect "shell: unknown command" $S '^hamsh: command not found: no-such-command$'
expect "shell: 2> redirects the error stream" $S '^ls: listdir failed: /nowhere$'
expect "shell: a faulting program is ended with a report" $S "process [0-9]+ 'ptest' ended: unprivileged access violation at 0x20000000"
expect "shell: ... and the shell carries on, status 139" $S '^after the fault 139$'
expect "shell: script file run by a second hamsh" $S '^script started$'
expect "shell: script: pipeline into a file" $S "^$NPROG $NPROG [0-9]+\$"
expect "shell: script: for loop" $S '^script word beta$'
expect "shell: script: arithmetic and if" $S '^script n is 42$'
expect "shell: script: built-in into a pipe" $S '^1 2 13$'
expect "shell: script: exit status" $S '^script status 5$'
expect "shell: Ctrl-C ends a looping foreground program (status 130)" $S '^interrupted 130$'
expect "shell: Ctrl-C ends a program that waits for console input" $S '^again 130$'
expect "shell: ls /sd shows the files of the FAT volume" $S '^PATTERN\.BIN$'
expect "shell: cat a file from the card" $S '^Hamnix Micro reads it through Hamnix fs/fat.ad\.$'
n40k="$(grep -c '^157 627 40000$' $S)"
[ "$n40k" = 2 ] && ok "shell: cp card -> tmpfs -> card, 40000 bytes each way" || bad "shell: the 40000-byte copies were counted $n40k times, expected 2"
expect "shell: a program run from the card" $S '^from the card 2$'
expect "shell: rm on the card" $S '^cat: cannot open /sd/BACK.BIN: .*file does not exist'
# milestone 4
expect "shell: a background job is listed by jobs" $S '^\[1\]\+ Running ptest loop$'
expect "shell: ps (Hamnix's, reading /proc/tasks) shows the job as a process" $S '^ +[0-9]+ +[0-9]+ (ready|run) +4 proc +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ ptest$'
expect "shell: kill PID ends it (a note to /proc/PID/note); the shell reports the job done" $S '^\[1\]\+ Done ptest loop$'
[ "$(grep -c '^0$' $S)" = 2 ] && ok "shell: no ptest process is left, after the kill and after Ctrl-C on the pipeline" || bad "shell: expected two '0' counts of ptest in /proc/tasks, got $(grep -c '^0$' $S)"
expect "shell: > file 2>&1 keeps the two streams in order in one file" $S '^err two$'
[ "$(grep -c '^3 6 26$' $S)" = 2 ] && ok "shell: ... 26 bytes, nothing overwritten; and Tab completed /tmp/bo to /tmp/both" || bad "shell: '3 6 26' seen $(grep -c '^3 6 26$' $S) times, expected 2"
expect "shell: def and a call" $S '^hello world from a function$'
[ "$(grep -c '^history-probe$' $S)" = 2 ] && ok "shell: up-arrow recalls an earlier line" || bad "shell: history-probe seen $(grep -c '^history-probe$' $S) times, expected 2"
expect "shell: Tab completes a command name (ec -> echo)" $S '^completed-command$'
expect "shell: Ctrl-C ends a three-stage pipeline (status 130)" $S '^pipeline interrupted 130$'
expect "shell: no here-documents: cat << EOF reads the console until Ctrl-C" $S '^no-heredoc 130$'
expect "shell: seq, sort -r, head" $S '^5$'
expect "shell: sort | uniq -c" $S '^ *2 pear$'
expect "shell: tr" $S '^SHOUT$'
expect "shell: od" $S '^61 62 63 0a$'
expect "shell: cut" $S '^mid$'
expect "shell: tee into a file and a pipe" $S '^1 1 12$'
expect "shell: ... the file" $S '^through-tee$'
expect "shell: mv" $S '^moved-u$'
expect "shell: touch" $S '^touched$'
expect "shell: free (Hamnix's, reading /proc/meminfo)" $S '^Mem: +[0-9]+ +[0-9]+$'
expect "shell: df (reading /proc/mounts)" $S '^sd0 +/sd +vfat +rw$'
expect "shell: date before the clock is set says so and fails" $S '^date-unset 1$'
expect "shell: setdate, then date" $S '^2026-11-27 12:00:0[0-9] UTC$'
up="$(sed -n 's/^\([0-9]*\)\.[0-9]* \([0-9]*\)\.[0-9]*$/\1 \2/p' $S | tail -1)"
if [ -n "$up" ]; then set -- $up; [ "$2" -ge 2 ] && ok "shell: sleep 2 was spent idle (/proc/uptime: up $1 s, idle $2 s)" || bad "shell: idle time $2 s after sleep 2"; else bad "shell: no /proc/uptime line"; fi
expect "keyboard: a command typed key by key on the emulated matrix (Shift for capitals and _) ran" $S '^Typed On The Matrix 2026 x_y$'
expect "vi: left with :wq, status 0" $S '^vi-status 0$'
expect "vi: insert with a correction, dd, O" $S '^second limne$'
expect "vi: G \$ x x" $S '^thi$'
expect "vi: o" $S '^appended via o$'
[ "$(grep -c '^4 7 36$' $S)" = 2 ] && ok "vi: the file is 4 lines, 36 bytes; an edit abandoned with :q! left it alone" || bad "vi: '4 7 36' seen $(grep -c '^4 7 36$' $S) times, expected 2"
grep -aq 'E: no write since last change (:q! overrides)' $B/shell.out && ok "vi: :q with unsaved changes is refused (its status line says so)" || bad "vi: no refusal of :q with unsaved changes"
wk="$(sed -n 's/^  processor wake-ups from sleep: *\([0-9]*\)\.[0-9]* per second.*/\1/p' $S | tr '\n' ' ')"
set -- $wk
if [ $# = 2 ]; then
    echo "[test] info: idle at the shell: $1 processor wake-ups per second with tickless idle, $2 with the periodic tick"
    [ "$1" -le 20 ] && ok "shell: idle with tickless idle: $1 wake-ups per second (20 or fewer)" || bad "shell: $1 wake-ups per second with tickless idle"
    [ "$2" -ge 900 ] && ok "shell: the same with the periodic tick: $2 per second" || bad "shell: $2 wake-ups per second with the periodic tick, expected about 1000"
else
    bad "shell: idlestat printed '$wk'"
fi
expect "shell: idlestat: fewer than 100 tick interrupts a second while idle, the display's refreshes included (1000 with the periodic tick)" $S '^  tick interrupts taken: +[0-9]{1,2}\.[0-9] per second'
expect "shell: suspend, ended by a key after about 1.5 s" $S '^woke: console after 1[0-9][0-9][0-9] ms, processor woken [0-9]+ times in all suspends$'
expect "shell: suspend 2 -n, ended by its timer after 2000 ms" $S '^woke: timer after 2000 ms, processor woken [0-9]+ times in all suspends$'
[ "$(grep -c '^persistent-history-probe$' $S)" = 2 ] && ok "shell: history survives exit: the next shell recalls a line of the previous one" || bad "shell: persistent-history-probe seen $(grep -c '^persistent-history-probe$' $S) times, expected 2"
expect "shell: a pasted block of 60 command lines (2 KB in one write): every line ran, in order" $S '^60 180 900$'
# milestone 5: namespaces
expect "ns: the shell's namespace is the boot namespace (six binds)" $S '^6 18 86$'
expect "ns: a bind made inside \`ns { }\` (a child after rfork RFNAMEG) works there: file read, seven binds" $S '^7 21 111$'
expect "ns: ... and is invisible to the parent" $S '^cat: cannot open /tmp/un/afile: .*file does not exist'
[ "$(grep -c '^6 18 86$' $S)" = 2 ] && ok "ns: the parent's namespace is unchanged after the block" || bad "ns: '6 18 86' seen $(grep -c '^6 18 86$' $S) times, expected 2"
expect "union: a name both directories have comes from the first" $S '^from-a$'
expect "union: a name only the second has is found there" $S '^only-b$'
expect "union: the listing is both directories' names, each once (shared, afile, bfile)" $S '^3 3 19$'
expect "union: a new file goes to the first member when none has MCREATE" $S '^3 3 21$'
expect "union: with a -bc member a new file goes to that one" $S '^cfile$'
expect "ns: /proc/self/ns lists the union in bind order with its flags" $S "^bind -bc '#t/tmp/uc' /tmp/un\$"
expect "ns: replay: the script ran" $S '^replay-status 0$'
sed -n '/^saved-ns-follows$/,/^replayed-ns-follows$/p' $S | grep '^bind\|^mount' > $B/ns.saved
sed -n '/^replayed-ns-follows$/,/^ns-texts-end$/p' $S | grep '^bind\|^mount' > $B/ns.replayed
[ "$(grep -c . $B/ns.saved)" = 9 ] && cmp -s $B/ns.saved $B/ns.replayed && ok "ns: the 9 lines of /proc/self/ns, run in an empty namespace (\`ns clean\`), build a namespace that prints the same 9 lines" \
    || bad "ns: replay differs: $(grep -c . $B/ns.saved) lines saved, $(grep -c . $B/ns.replayed) replayed"
grep -q '^3 11 82$' $S && grep -q '^4 14 109$' $S && ok "ns: /proc/PID/ns of a job started before a bind has 3 lines naming /tmp, the shell's own has 4" || bad "ns: the job's and the shell's /proc/<pid>/ns do not differ as expected"
expect "ns: unmount removes the union" $S '^cat: cannot open /tmp/un/shared: .*file does not exist'
expect "ns: bind -b over /bin replaces a program inside the block (seq is /bin/hello there)" $S '^  arg: 7$'
expect "ns: ... and only there" $S '^7$'
expect "ns: a template made with \`ns clean\`, entered: the root is /tmp/ua plus the mount points /bin and /fd" $S '^5 5 28$'
expect "ns: ... and nothing else is reachable in it" $S '^cat: cannot open /tmp/copy: .*file does not exist'
expect "ns: \`with bind\` binds for the block" $S '^ONLY-B$'
expect "ns: ... and unbinds at its end" $S '^cat: cannot open /tmp/un/bfile: .*file does not exist'
expect "ns: bind of a source that does not exist fails with the kernel's error string" $S '^bind: bind failed: source does not resolve in this namespace$'
# milestone 5: drivers as files
expect "devices: the script ran to its end" $S '^devices-script 0$'
expect "devices: cat /dev/sht4x/temperature (the model set to 25 C with echo)" $S '^24\.998$'
expect "devices: cat /dev/sht4x/humidity" $S '^56\.500$'
expect "devices: a negative temperature" $S '^-34\.063$'
expect "devices: ... and humidity" $S '^-4\.047$'
expect "devices: the sensor's serial number" $S '^0f3a9b2c$'
expect "devices: the same sensor through /dev/i2c/0/ctl: write 89, read 6 bytes" $S '^0f 3a 06 9b 2c 2d$'
expect "devices: an I2C address without a device" $S '^nack$'
[ "$(grep -c '^H$' $S)" = 3 ] && [ "$(grep -c '^L$' $S)" = 1 ] && ok "devices: /dev/gpio/2 driven 1, 0, 1 in a loop reads H, L, H at the pin wired to it; a pin driven from outside reads H" \
    || bad "devices: gpio levels: $(grep -c '^H$' $S) H and $(grep -c '^L$' $S) L, expected 3 and 1"
expect "devices: the model shows pin 2 as an output at 1" $S '^2 out 1$'
expect "devices: /dev/screen/ctl" $S '^size 800 480 depth 1 text 100 30 refreshes [0-9]+$'
expect "devices: /dev/power/ctl switches tickless idle off" $S '^tickless: +0$'
expect "devices: ls /dev/sht4x" $S '^temperature$'
expect "devices: text written to /dev/screen/text is on the screen (read back from /dev/screen/text)" $S '^Shown-On-Panel$'
expect "devices: /dev/screen/data is the frame buffer, 48000 bytes" $S '^[0-9]+ [0-9]+ 48000$'
expect "devices: text written to /dev/keys is typed on the emulated key matrix and runs as a command" $S '^Typed-Via-Dev-Keys$'
expect "devices: ls /dev: console, null, zero and seven driver directories and files" $S '^10 10 [0-9]+$'
# the same session as the fake e-paper panel showed it
P=$B/panel-shell.txt
python3 -I tests/display/panel2png.py $B/panel-shell.bin $B/panel-shell --font third_party/font8x8/font8x8_basic.h --yscale 2 --keep 3 > $P 2>&1; prc=$?
grep '^records:\|^image:' $P
awk '/^text:$/{f=1; next} f' $P | grep -v '^$' | tail -8 | sed 's/^/    | /'
[ $prc -eq 0 ] && ok "display: the session's panel stream is well-formed" || bad "display: panel2png.py failed on the session's stream ($prc)"
nfull="$(sed -n 's/^records: full \([0-9]*\) partial \([0-9]*\).*/\1/p' $P)"; npart="$(sed -n 's/^records: full \([0-9]*\) partial \([0-9]*\).*/\2/p' $P)"
[ "${npart:-0}" -ge 3 ] && [ "${nfull:-0}" -ge 2 ] && ok "display: the console reached the panel in $nfull full and $npart partial refreshes" || bad "display: $nfull full and $npart partial refreshes"
awk '/^text:$/{f=1; next} f' $P | grep -q '^60 180 900$' && awk '/^text:$/{f=1; next} f' $P | grep -q '^hamsh\$ halt 0$' \
    && ok "display: the last frame, read back from its pixels, shows the end of the session (the paste count, 'hamsh\$ halt 0')" \
    || bad "display: the last frame does not show the end of the session"
nmark="$(grep -c '^0 0 0$' $S)"
[ "$nmark" = "$m" ] && ok "shell: all $m commands were answered" || bad "shell: $nmark of $m commands answered"

fi
echo
if [ $fails -eq 0 ]; then echo "[test] ALL TESTS PASSED"; exit 0; fi
echo "[test] $fails TEST(S) FAILED"; exit 1
