# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# BOARD=teensy41: PJRC Teensy 4.1.  UNTESTED ON HARDWARE.
#   make BOARD=teensy41            build/teensy41/hackos.elf, .bin, .hex
#   make test-teensy               everything that can be checked without it
# The image is the system image (init + shell); the QEMU test images do not
# exist for this board.  Programs are built for size (they are copied into
# the 512 KB program arena to run), and the copied Hamnix code carries
# per-board size patches (boards/teensy41/patches/, applied in build/teensy41/root
# only).
IMAGES := hackos
BOARD_ALL := $(B)/hackos.hex $(B)/hackos.bin
PROG_AFLAGS := --llvm-optsize
BOARD_PATCHES := $(wildcard boards/teensy41/patches/*/*.patch boards/teensy41/patches/*/*/*.patch)
# The shell's stack: 32 KiB instead of 64 (with its size patch the shell is
# then a 448 KiB block, 7/8 of a 512 KiB MPU region).
STACK_hamsh := 32768
