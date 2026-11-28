#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# The Feather nRF52840 image, unchanged (build/feather-nrf52840/hmicro.elf),
# in Renode's nRF52840 machine (tests/nrf52/feather_nrf52840.repl: Renode's
# own models of the Cortex-M4F with its NVIC and MPU, UARTE0, RTC1, CLOCK,
# GPIO, 1 MB flash and 256 KB RAM), started the way Adafruit's bootloader
# starts it: MSP and PC from the vector table at 0x26000.  The console is
# Renode's server socket terminal on UARTE0; tests/nrf52/uart_session.py
# types session.txt at it.  Then the transcript is checked.
# What this does NOT cover: the bootloader itself, real clock and UART
# timing, the crystal oscillators (Renode's CLOCK model reports them
# started), electrical levels, flash wait states.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
RENODE="${RENODE:-/var/tmp/hackerslide-agent/tools/dl-renode-1.17.1/renode_1.17.1-portable/renode}"
E=build/feather-nrf52840/hmicro.elf
B=build/nrf52/renode; mkdir -p $B
fails=0
ok()  { echo "[renode] ok: $1"; }
bad() { echo "[renode] FAIL: $1"; fails=$((fails+1)); }
expect() { if grep -Eq -- "$3" "$2"; then ok "$1"; else bad "$1 (no match for /$3/)"; fi; }
[ -x "$RENODE" ] || { echo "[renode] SKIP: no Renode at $RENODE (set RENODE=)"; exit 77; }
[ -f $E ] || { echo "[renode] FAIL: $E missing (make BOARD=feather-nrf52840)"; exit 1; }
PORT=$(( 20000 + RANDOM % 20000 ))
cat > $B/session.resc <<RESC
mach create "feather"
machine LoadPlatformDescription @$(pwd)/tests/nrf52/feather_nrf52840.repl
sysbus LoadELF @$(pwd)/$E
cpu VectorTableOffset 0x26000
emulation CreateServerSocketTerminal $PORT "term" false
connector Connect sysbus.uart0 term
start
RESC
# Renode's console mode ends when its standard input does: give it one
# that stays open for the length of the session.
rm -f $B/stdin; mkfifo $B/stdin
"$RENODE" --disable-gui --console -e "include @$(pwd)/$B/session.resc" < $B/stdin > $B/renode.log 2>&1 &
RPID=$!
exec 8>$B/stdin
python3 -I tests/nrf52/uart_session.py 127.0.0.1:$PORT "${SESSION:-tests/nrf52/session.txt}" $B/console.raw 2> $B/driver.log
drc=$?
kill $RPID 2>/dev/null; wait $RPID 2>/dev/null; exec 8>&-; rm -f $B/stdin
cat $B/driver.log
sed 's/\r*$//; s/.*\r//; s/\x1b\[[0-9;?]*[A-Za-z]//g' < $B/console.raw | grep -v '^\[hamsh:stage' > $B/console.txt
S=$B/console.txt
sed 's/^/    /' $S
[ "$drc" = 0 ] && ok "every command was answered" || bad "$drc waits failed (driver.log)"
NPROG=$(ls build/feather-nrf52840/user | grep -cv '\.')
expect "boot banner names the board and the M4F" $S '^Hamnix Micro 0\.[0-9]+ \(milestone [0-9]+\) -- ARM Cortex-M4F, Adafruit Feather nRF52840 Express'
expect "the clocks report" $S '^clocks: HFCLK from the 32 MHz crystal, LFCLK from the RC oscillator$'
expect "/bin runs in place from its flash window" $S '^/bin in place at 0x00060000\.\.'
expect "hamsh runs as a process (its banner)" $S "^hamsh . Hamnix shell"
expect "a built-in" $S '^hello from hamsh$'
expect "ls /bin" $S '^hamsh$'
expect "ls | wc counts the $NPROG programs" $S "^$NPROG $NPROG [0-9]+\$"
expect "ls | grep" $S '^halt$'
expect "a four-stage pipeline (four children beside the shell)" $S '^2 2 [0-9]+$'
n5="$(grep -cE "^$NPROG $NPROG [0-9]+\$" $S)"
[ "$n5" -ge 2 ] && ok "a pipeline of five programs beside the shell (ls | cat | cat | cat | wc)" || bad "the five-program pipeline did not count the programs ($n5)"
expect "a sixth program in a pipeline does not fit (kernel heap: its kernel stack) and fails cleanly" $S '^hamsh: command not found: cat$'
expect "a built-in as the first stage of a pipeline" $S '^1 4 22$'
expect "> and >> to a file, read back" $S '^second line$'
expect "< from a file" $S '^2 4 23$'
expect "cp, mkdir, ls /tmp" $S '^copy$'
expect "head" $S '^first line$'
expect "arguments and exit status of a program" $S '^status was 3$'
expect "a binary file (an RWPI ELF) through a pipe" $S "^[0-9]+ [0-9]+ $(stat -c %s build/feather-nrf52840/user/hello)\$"
expect "a program not in /bin: its code copied into RAM, not run in place" $S '^copied program status 3$'
expect "unknown command" $S '^hamsh: command not found: no-such-command$'
expect "the MPU stops a process reading kernel RAM; the shell carries on" $S '^after the fault 139$'
expect "... reported as an access violation" $S "process [0-9]+ 'ptest' ended: unprivileged access violation at 0x20000000"
expect "Ctrl-C ends a looping program (UARTE receive interrupt)" $S '^interrupted 130$'
expect "no /sd on this board" $S 'ls: .*/sd'
expect "script by source: started" $S '^script started$'
expect "script: for loop" $S '^script word beta$'
expect "script: arithmetic and if" $S '^script n is 42$'
expect "script: built-in into a pipe" $S '^1 2 13$'
# float64 in the shell: here compiler-rt's soft double precision; the
# expected strings are what the same shell prints on QEMU's Cortex-M7
# (hardware double precision), and what the arithmetic says.
expect "soft double: 7.5 / 2.5 + 0.25" $S '^f1 3\.25$'
expect "soft double: 1.0 / 3.0 (rounding of the last digits)" $S '^f2 0\.333333333333$'
expect "soft double: 2.5 * 4.0 - 0.1" $S '^f3 9\.9$'
expect "soft double: 10.0 / 4 (int to double)" $S '^f5 2\.5$'
if grep -q '^second shell status 0$' $S; then bad "a second shell started: the arena should not hold two"
else ok "a second shell does not fit and fails cleanly: $(grep -m1 '^second shell status' $S)"; fi
n12="$(grep -cE '^1 2 [78]$' $S)"
[ "$n12" = 12 ] && ok "a loop of 12 pipelines, 24 processes one after another" || bad "the loop of 12 pipelines printed $n12 counts"
expect "ps: Hamnix's, reading /proc/tasks" $S '^ +[0-9]+ +[0-9]+ run +4 proc +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ ps$'
expect "free and df" $S '^Mem: +[0-9]+ +[0-9]+$'
expect "setdate and date" $S '^2026-11-27 12:00:0[0-9] UTC$'
expect "a background job" $S '^\[1\]\+ Running ptest loop$'
expect "> file 2>&1" $S '^err two$'
expect "seq, sort -r | head" $S '^5$'
expect "tr" $S '^SHOUT$'
expect "mv" $S '^moved-n$'
expect "Ctrl-C ends a pipeline (cat | wc: both wait, the shell names no group for them)" $S '^pipeline interrupted 130$'
expect "kill PID ends the background job" $S '^\[1\]\+ Done ptest loop$'
expect "vi: scripted keystrokes, left with :wq" $S '^vi-status 0$'
expect "vi: the file it wrote is 4 lines, 36 bytes" $S '^4 7 36$'
expect "vi: insert with a correction, dd, O, G \$ x x, o" $S '^appended via o$'
wk="$(sed -n 's/^  processor wake-ups from sleep: *\([0-9]*\)\.[0-9]* per second.*/\1/p' $S | tr '\n' ' ')"
set -- $wk
if [ $# = 2 ]; then
    echo "[renode]   idle at the shell: $1 processor wake-ups per second with tickless idle (RTC1 compare), $2 with the periodic tick"
    [ "$1" -le 20 ] && ok "idle with tickless idle: $1 processor wake-ups per second (20 or fewer)" || bad "$1 wake-ups per second with tickless idle"
    [ "$2" -ge 900 ] && ok "the same with the periodic tick: $2 per second" || bad "$2 wake-ups per second with the periodic tick, expected about 1000"
else
    bad "idlestat printed '$wk'"
fi
expect "suspend, ended by a byte at the console" $S '^woke: console after [0-9]+ ms, processor woken [0-9]+ times in all suspends$'
expect "suspend 2 -n (UARTE receiver off, crystal released), ended by RTC1 after 2000 ms" $S '^woke: timer after 2000 ms, processor woken [0-9]+ times in all suspends$'
expect "a pasted block of 40 command lines (1.4 KB in one write): every line ran, in order" $S '^40 120 600$'
expect "... with the sender held off while the shell worked, and nothing dropped" $S '^console: [0-9]+ bytes in, input ring peak [0-9]+, sender held off [1-9][0-9]* times, dropped 0, UART overruns 0, other UART errors 0, DMA guard intact$'
grep '^console:' $S | sed 's/^/[renode]   /'
expect "'halt 0' ends the run with status 0" $S '^\[hmicro\] exit status 0$'
expect "memory report" $S '^memory: kernel heap peak [0-9]+ of [0-9]+, program arena peak [0-9]+$'
grep '^memory:' $S | sed 's/^/[renode]   /'
grep -c 'fault\|FAULT' $S >/dev/null
echo "[renode] $fails failures"
exit $fails
