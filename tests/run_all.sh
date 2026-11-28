#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# HackOS test runner (called by `make test` after the images are built).
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
B="${HACKOS_B:-build}"
MACHINE="${HACKOS_MACHINE:-mps2-an500}"
XP="${HACKOS_XP:-60}"
ONLY="${HACKOS_ONLY:-1 2 3 4 5 6 7 8}"
want() { case " $ONLY " in *" $1 "*) return 0;; esac; return 1; }
# An image ends its run by printing "[hackos] exit status N" and requesting a
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
# the image's last "[hackos] exit status N" line, 125 if it printed none.
run_status() {  # run_status <logfile> <exit status of timeout/qemu>
    [ "$2" -eq 124 ] && return 124
    local n; n="$(tr -d '\r' < "$1" | sed -n 's/^\[hackos\] exit status \([0-9]*\)$/\1/p' | tail -1)"
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
    timeout 120 "$QEMU" $QFLAGS ${3:-} -kernel "$1" <$B/uart.in >"$2" 2>"$2.err" &
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
    head -1 "$path" | grep -q '^# HackOS: copied from Hamnix' || { bad "$path has no origin header"; continue; }
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
for img in hackos monitor ktest selftest; do
    undef="$("$NM" -u $B/$img.elf | wc -l)"
    [ "$undef" = 0 ] && ok "$img: no undefined symbols" || bad "$img: $undef undefined symbols"
done
sym() { "$NM" $B/$1.elf | awk -v s="$2" '$3==s{print $1}'; }
word() {  # word <img> <address>: little-endian word of the flash image at that address
    [ -f $B/$1.bin ] || "$OBJCOPY" -O binary -j .boot -j .text $B/$1.elf $B/$1.bin
    od -An -tx4 -j $(($2)) -N 4 $B/$1.bin | tr -d ' '
}
[ "$(sym hackos hackos_boot_vectors)" = "00000000" ] && ok "boot vectors at 0x00000000" || bad "boot vectors at $(sym hackos hackos_boot_vectors)"
[ "$(sym hackos hackos_vectors)" = "00001000" ] && ok "vector table at 0x00001000, behind the null guard" || bad "vector table at $(sym hackos hackos_vectors)"
[ "$(word hackos 0)" = "$(sym hackos __stack_top)" ] && ok "word 0 is the initial stack pointer (0x$(word hackos 0))" || bad "word 0 is $(word hackos 0)"
[ "$((0x$(word hackos 4)))" = "$((0x$(sym hackos Reset_Handler) + 1))" ] && ok "word 4 is Reset_Handler with the Thumb bit" || bad "word 4 is $(word hackos 4)"
[ "$(word hackos 0x20)" = "00000000" ] && [ "$(word hackos 0xffc)" = "00000000" ] && ok "nothing else lives in the first 4 KB" || bad "the null-guard area is not empty"
for v in "11:svc_handler" "14:pendsv_handler" "15:systick_handler" "16:uart0_rx_handler"; do
    n="${v%%:*}"; s="${v#*:}"
    [ "$((0x$(word hackos $((0x1000 + n*4)))))" = "$((0x$(sym hackos $s) + 1))" ] && ok "vector $n is $s" || bad "vector $n is $(word hackos $((0x1000 + n*4))), $s is $(sym hackos $s)"
done
fp="$(grep -cE 'v(mul|div|add|sub)\.f64' $B/selftest.lst)"
[ "$fp" -gt 20 ] && ok "self-test uses double-precision FPU instructions ($fp)" || bad "only $fp f64 FPU instructions"
soft="$(cat $B/hackos.lst $B/ktest.lst $B/selftest.lst | grep -cE '__aeabi_d(add|sub|mul|div)|__adddf3|__muldf3')"
[ "$soft" = 0 ] && ok "no soft-float arithmetic calls" || bad "$soft soft-float calls"
vol="$(awk '/^define .*@test_volatile_mmio\(/{f=1} f&&/(load|store) volatile i32/{n++} /^}/{f=0} END{print n+0}' $B/selftest.ll)"
[ "$vol" = 7 ] && ok "test_volatile_mmio: 5 volatile loads + 2 volatile stores of CTRL in the IR" || bad "test_volatile_mmio has $vol volatile accesses, want 7"
dsz="$("$SIZE" -A $B/hackos.elf | awk '$1==".data"{print $2}')"
nstr="$(grep -c '^@\.Lstr.* = internal constant' $B/hackos.ll)"; nstrw="$(grep -c '^@\.Lstr.* = internal global' $B/hackos.ll)"
[ "$nstrw" = 0 ] && [ "$nstr" -gt 100 ] && [ "$dsz" -lt 2048 ] && ok "string literals are constants ($nstr of them; .data is $dsz bytes)" || bad "string literals: $nstr constant, $nstrw writable, .data $dsz bytes"
tb="$("$SIZE" -A $B/hackos.elf | awk '$1==".xbss"{print $3}')"
[ "$((tb))" = "$((0x60000000))" ] && ok "the large file-system table is placed in the 16 MB region" || bad ".xbss at $tb"
nv="$(grep -c '^define void @' $B/hackos.ll)"
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
qemu_start $B/ktest.elf $B/ktest.out "$ICOUNT $SDCARD"
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

fi
if want 6; then
echo "[test] === 6. monitor session over the UART (real-time clock, commands typed by the harness)"
qemu_start $B/monitor.elf $B/monitor.out
p=0
cmd() {  # send one command line and wait for the next prompt
    p=$((p+1))
    wait_for "hackos> " $p || { bad "no prompt #$p from the monitor"; return 1; }
    say "$1\\r"
}
cmd 'help'
cmd 'ps'
cmd 'heap'
cmd 'mkdir /tmp/d'
cmd 'write /tmp/d/hello.txt Hello,  HackOS!'
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
expect "monitor: banner" $M '^HackOS 0\.2 \(milestone 2\)'
expect "monitor: 29 prompts" $M 'hackos> halt 0'
expect "monitor: help lists the commands" $M '^  ps +threads: state'
expect "monitor: ps lists the idle thread" $M '^ +1 idle +ready +7 kern +[0-9]+/ +[0-9]+ +- +[0-9]+ +[0-9]+$'
expect "monitor: ps shows itself running with its stack high-water mark" $M '^ +3 monitor +running +2 kern +[0-9]+/ 15360 '
expect "monitor: heap statistics, consistent" $M '^kernel heap: total [0-9]+  used [0-9]+  peak [0-9]+  free [0-9]+ in [0-9]+ block'
expect "monitor: heap consistency check is 0" $M 'requested bytes live [0-9]+  consistency 0$'
expect "monitor: write reports the byte count" $M '^wrote 16 bytes to /tmp/d/hello.txt$'
expect "monitor: ls / shows dev, tmp and etc" $M '^dev$'
expect "monitor: ls shows the new file" $M '^hello.txt$'
expect "monitor: cat prints the first line" $M '^Hello,  HackOS!$'
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
expect "reported as UsageFault" $B/faulttest.out 'HackOS FAULT: UsageFault \(exception 6\)'
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
qemu_start $B/hackos.elf $B/shell.out "$SDCARD"
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
expect "shell: banner of the system image" $S '^HackOS 0\.[0-9]+ \(milestone [0-9]+\)'
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
expect "shell: cat a file from the card" $S '^HackOS reads it through Hamnix fs/fat.ad\.$'
n40k="$(grep -c '^157 627 40000$' $S)"
[ "$n40k" = 2 ] && ok "shell: cp card -> tmpfs -> card, 40000 bytes each way" || bad "shell: the 40000-byte copies were counted $n40k times, expected 2"
expect "shell: a program run from the card" $S '^from the card 2$'
expect "shell: rm on the card" $S '^cat: cannot open /sd/BACK.BIN: .*file does not exist'
expect "shell: a pasted block of 60 command lines (2 KB in one write): every line ran, in order" $S '^60 180 900$'
nmark="$(grep -c '^0 0 0$' $S)"
[ "$nmark" = "$m" ] && ok "shell: all $m commands were answered" || bad "shell: $nmark of $m commands answered"

fi
echo
if [ $fails -eq 0 ]; then echo "[test] ALL TESTS PASSED"; exit 0; fi
echo "[test] $fails TEST(S) FAILED"; exit 1
