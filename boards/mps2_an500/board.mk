# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# BOARD=qemu-mps2 (the default): QEMU `-M mps2-an500`, the machine every test
# of `make test` runs on.  Nothing is patched for this board.
IMAGES := hmicro monitor ktest selftest faulttest
# This board has a display (a fake e-paper panel, drivers/display/): its
# images link the glyph table.
BOARD_COBJS := $(B)/c/font8x8.o
