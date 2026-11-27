#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# The Feather nRF52840 image, unchanged (build/feather-nrf52840/hackos.elf),
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
E=build/feather-nrf52840/hackos.elf
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
python3 -I tests/nrf52/uart_session.py 127.0.0.1:$PORT tests/nrf52/session.txt $B/console.raw 2> $B/driver.log
drc=$?
kill $RPID 2>/dev/null; wait $RPID 2>/dev/null; exec 8>&-; rm -f $B/stdin
cat $B/driver.log
sed 's/\r*$//; s/.*\r//; s/\x1b\[[0-9;?]*[A-Za-z]//g' < $B/console.raw | grep -v '^\[hamsh:stage' > $B/console.txt
S=$B/console.txt
sed 's/^/    /' $S
[ "$drc" = 0 ] && ok "every command was answered" || bad "$drc waits failed (driver.log)"
NPROG=$(ls build/feather-nrf52840/user | grep -cv '\.')
expect "boot banner names the board and the M4F" $S '^HackOS 0\.3 \(milestone 3\) -- ARM Cortex-M4F, Adafruit Feather nRF52840 Express'
expect "the clocks report" $S '^clocks: HFCLK from the 32 MHz crystal, LFCLK from the RC oscillator$'
expect "/bin runs in place from its flash window" $S '^/bin in place at 0x00080000\.\.'
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
expect "a binary file (an RWPI ELF) through a pipe" $S "^[0-9]+ [0-9]+ $(stat -c %s build/feather-nrf52840/user/hello)\$"
expect "a program not in /bin: its code copied into RAM, not run in place" $S '^copied program status 3$'
expect "unknown command" $S '^hamsh: command not found: no-such-command$'
expect "the MPU stops a process reading kernel RAM; the shell carries on" $S '^after the fault 139$'
expect "... reported as an access violation" $S "process [0-9]+ 'ptest' ended: unprivileged access violation at 0x20000000"
expect "Ctrl-C ends a looping program (UARTE receive interrupt)" $S '^interrupted 130$'
expect "no /sd on this board" $S 'ls: .*/sd'
expect "script by source: started" $S '^script started$'
expect "script: for loop" $S '^script word beta$'
expect "script: arithmetic and if (soft double precision)" $S '^script n is 42$'
expect "script: built-in into a pipe" $S '^1 2 13$'
if grep -q '^second shell status 0$' $S; then bad "a second shell started: the arena should not hold two"
else ok "a second shell does not fit and fails cleanly: $(grep -m1 '^second shell status' $S)"; fi
n12="$(grep -cE '^1 2 [78]$' $S)"
[ "$n12" = 12 ] && ok "a loop of 12 pipelines, 24 processes one after another" || bad "the loop of 12 pipelines printed $n12 counts"
expect "'halt 0' ends the run with status 0" $S '^\[hackos\] exit status 0$'
expect "memory report" $S '^memory: kernel heap peak [0-9]+ of [0-9]+, program arena peak [0-9]+$'
grep '^memory:' $S | sed 's/^/[renode]   /'
grep -c 'fault\|FAULT' $S >/dev/null
echo "[renode] $fails failures"
exit $fails
