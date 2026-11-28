#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# `make test-teensy`: everything about the Teensy 4.1 port that can be checked
# without the board.  Nothing here proves the hardware works; see
# docs/boards/teensy41.md for what is and is not covered.
#   1. third_party/nxp-mcux-rt1062 is byte-identical to the recorded upstream
#   2. register constants against MIMXRT1062.h / fsl_clock.h   (check_regs.py)
#   3. pin mux and pad settings against fsl_iomuxc.h and PJRC's pin table
#   4. the boot header of build/teensy41/hmicro.{elf,bin,hex}    (check_boot.py)
#   5. the uSDHC + SD card driver against QEMU's models          (usdhc_qemu.sh)
#   6. LPUART, LPI2C, LPSPI, GPIO, clock arithmetic against register models
#      in a QEMU mps2-an500 image                                (drvtest.sh)
#   7. the Teensy's programs and kernel size patches, in QEMU, in a memory map
#      the size of the Teensy's                                  (t41mem.sh)
# PJRC_CORES=<checkout of PaulStoffregen/cores> adds the comparisons with
# PJRC's files (FCB, pin table); without it they are skipped, with a note.
# Exit status: number of failed steps.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ADDER="${ADDER:-../adder}"; export ADDER
B=build/teensy41
NXP=third_party/nxp-mcux-rt1062
LOG=build/imxrt; mkdir -p $LOG
failed=0
step() {  # step <name> <command...>: run, keep the log, count a failure
    local name="$1"; shift
    if "$@" > $LOG/$name.log 2>&1; then echo "[imxrt] ok: $name ($(grep -c 'ok:' $LOG/$name.log) checks)"
    else echo "[imxrt] FAIL: $name (see $LOG/$name.log)"; grep -E 'FAIL' $LOG/$name.log | head -20; failed=$((failed+1)); fi
}
hashes() {
    local n=0 bad=0
    local sum fname
    while read -r sum fname; do
        [ ${#sum} = 64 ] || continue
        n=$((n+1))
        if [ "$(sha256sum < $NXP/$fname | cut -d' ' -f1)" = "$sum" ]; then echo "ok: $fname"; else echo "FAIL: $fname differs from upstream"; bad=1; fi
    done < <(sed -n '/^Files taken/,/^$/p' $NXP/UPSTREAM)
    [ $n = 8 ] || { echo "FAIL: $n files listed, expected 8"; bad=1; }
    return $bad
}
PJ_BOOT=""; PJ_PINS=""
if [ -n "${PJRC_CORES:-}" ]; then PJ_BOOT="$PJRC_CORES/teensy4/bootdata.c"; PJ_PINS="$PJRC_CORES/teensy4/core_pins.h"
else echo "[imxrt] note: PJRC_CORES not set: the FCB and pin table are not compared with PJRC's files this run"; fi
step third_party hashes
step regs python3 -I tests/imxrt/check_regs.py $NXP
step pins python3 -I tests/imxrt/check_pins.py $NXP $PJ_PINS
step boot python3 -I tests/imxrt/check_boot.py $B/hmicro.elf $B/hmicro.bin $B/hmicro.hex $NXP $PJ_BOOT
step usdhc_qemu bash tests/imxrt/usdhc_qemu.sh
[ -f tests/imxrt/drvtest.sh ] && step drvtest bash tests/imxrt/drvtest.sh
[ -f tests/imxrt/t41mem.sh ] && step t41mem bash tests/imxrt/t41mem.sh
echo "[imxrt] $failed failed steps"
exit $failed
