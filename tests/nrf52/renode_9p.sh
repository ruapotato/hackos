#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# The Feather nRF52840 image in Renode (as tests/nrf52/renode_session.sh
# starts it), its console on a TCP socket, and tests/9p/host_test.py at the
# other end of that socket: `exportfs /dev/console` typed at the shell, then
# the device's tree used from the host over 9P2000 on the console's UARTE0.
# EMULATOR ONLY.  Renode's UARTE model queues received bytes without limit
# and has no baud rate: this shows the protocol and the console's wire mode
# on the real image, not that a real line at 115200 baud loses nothing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
RENODE="${RENODE:-/var/tmp/hackerslide-agent/tools/dl-renode-1.17.1/renode_1.17.1-portable/renode}"
E=build/feather-nrf52840/hmicro.elf
B=build/nrf52/renode9p; mkdir -p $B
[ -x "$RENODE" ] || { echo "[renode-9p] SKIP: no Renode at $RENODE (set RENODE=)"; exit 77; }
[ -f $E ] || { echo "[renode-9p] FAIL: $E missing (make BOARD=feather-nrf52840)"; exit 1; }
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
rm -f $B/stdin; mkfifo $B/stdin
"$RENODE" --disable-gui --console -e "include @$(pwd)/$B/session.resc" < $B/stdin > $B/renode.log 2>&1 &
RPID=$!
exec 8>$B/stdin
python3 -I tests/9p/host_test.py --tcp 127.0.0.1:$PORT build/feather-nrf52840/user/hello --halt
rc=$?
kill $RPID 2>/dev/null; wait $RPID 2>/dev/null; exec 8>&-; rm -f $B/stdin
exit $rc
