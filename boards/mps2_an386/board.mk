# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# BOARD=qemu-m4: QEMU `-M mps2-an386`, the same MPS2 board with a Cortex-M4F.
# It exists so that the Cortex-M4 path (single-precision FPU, software
# float64, the 8-region MPU) is run through the full kernel test suite and
# a shell session, not only through Renode's nRF52840 (`make test-m4`).
# Differences from qemu-mps2: the CPU, and the 16 MB RAM at 0x21000000
# instead of 0x60000000.  Programs are PIEs copied into RAM, as on qemu-mps2.
IMAGES := hmicro ktest
CPU := cortex-m4
FPU := fpv4-sp-d16
SOFT_DOUBLE := 1
# This board has a display (a fake e-paper panel, drivers/display/): its
# images link the glyph table.
BOARD_COBJS := $(B)/c/font8x8.o
# The emulated SHT4x is read by Sensirion's C driver (devices.ad).
BOARD_SHT4X := 1
