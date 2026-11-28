# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# BOARD=feather-nrf52840: Adafruit Feather nRF52840 Express (Nordic
# nRF52840, Cortex-M4F 64 MHz, 1 MB flash, 256 KB RAM).  UNTESTED ON HARDWARE.
#   make BOARD=feather-nrf52840       build/feather-nrf52840/hmicro.elf, .bin, .hex, .uf2
#   make test-nrf52                   everything that can be checked without it
#                                     (tests/nrf52/; boots it in Renode)
# Flashing: double-tap reset, copy hmicro.uf2 to the FTHR840BOOT drive
# (docs/boards/feather-nrf52840.md).
IMAGES := hmicro
BOARD_ALL := $(B)/hmicro.uf2 $(B)/hmicro.hex $(B)/hmicro.bin
CPU := cortex-m4
FPU := fpv4-sp-d16
SOFT_DOUBLE := 1
# Programs' code stays in flash (/bin), only their data goes to RAM.
PROG_ABI := rwpi
PROG_AFLAGS := --llvm-optsize
# Everything is compiled for size: the image must end below 0xAD000 (link.ld)
# and /bin starts at 0x60000, so the kernel has 232 KB and /bin 308 KB.  At
# -O2 the milestone-5 kernel alone is 228 KB and /bin 323 KB; at -Oz they
# are 123 KB and 271 KB (docs/boards/feather-nrf52840.md, size).  -Oz makes
# LLVM call __aeabi_llsl/llsr/lasr for 64-bit shifts (arch/armv7m/aeabi.S).
OPT ?= -Oz
# Programs left out of this board's /bin:
#   crel         tests absolute pointers in C data, which an RWPI program
#                cannot have
#   p9srv_demo   Hamnix's one-file 9P demo server (10 KB); exportfs is the 9P
#                server here
#   srv          posts a serial device in /srv; this board has no second
#                serial port as a file yet
# Everything else fits since the image is built with -Oz (below); the next to
# go if room is needed: ptest (12 KB, a test program), vi (9 KB), sort, cut,
# tr, idlestat (docs/boards/feather-nrf52840.md, size).
PROGS_SKIP := crel p9srv_demo srv
BOARD_PATCHES := $(wildcard boards/feather_nrf52840/patches/*/*.patch boards/feather_nrf52840/patches/*/*/*.patch)
# Application start of Adafruit's bootloader: after SoftDevice S140 6.1.1
# (what the Feather nRF52840 ships with; INFO_UF2.TXT on its drive says
# "SoftDevice: S140 6.1.1").  A bootloader with S140 7.x starts applications
# at 0x27000: build with NRF_APP_START=0x27000.
NRF_APP_START ?= 0x26000
UF2_FAMILY := 0xADA52840
LDFLAGS_BOARD := --defsym=__app_start=$(NRF_APP_START)
# Stacks (bytes; the rest of a program's block is its data).  Measured
# needs: docs/boards/feather-nrf52840.md, memory.
STACK_hamsh := 8192
STACK_DEFAULT_BOARD := 4096
STACK_grep := 8192
