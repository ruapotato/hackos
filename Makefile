# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# Hamnix Micro -- build and test.
#
#   make                    build the default board's image (BOARD=qemu-mps2)
#   make test               build everything for QEMU from source and run every
#                           test; non-zero exit status on any failure
#   make run                run the system in QEMU with the UART on the terminal
#   make size               text/data/bss of the image
#   make measure            cost of the i64 value model vs. C (tests/measure.sh)
#   make BOARD=teensy41     the Teensy 4.1 image: build/teensy41/hmicro.hex
#                           (docs/boards/teensy41.md)
#   make test-m4            the kernel tests and the shell session once more,
#                           on QEMU's Cortex-M4F machine (BOARD=qemu-m4)
#   make test-teensy        the checks that can be made without the board:
#                           boot header, register constants, pin table, the
#                           drivers against register models (tests/imxrt/)
#
# BOARD picks boards/<dir>/board.mk (the linker script, the vector table, which
# images exist, per-board size patches).  Adder code imports the board as
# `board.board`; the compiler runs in $(B)/root, a tree of links to these
# sources in which `board` is the selected board directory
# (scripts/mkroot.sh).  Output goes to build/ for qemu-mps2 and to
# build/<BOARD>/ for every other board.
#
# ADDER points at a checkout of the Adder compiler that has the
# thumbv7em-none-eabihf target (branch cortex-m7).  Nothing from that tree is
# copied here; its host compiler binary is bootstrapped there on first use.
BOARD   ?= qemu-mps2
BOARD_DIR_qemu-mps2 := mps2_an500
BOARD_DIR_teensy41  := teensy41
BOARD_DIR_feather-nrf52840 := feather_nrf52840
BOARD_DIR_qemu-m4   := mps2_an386
BOARD_DIR := $(BOARD_DIR_$(BOARD))
ifeq ($(BOARD_DIR),)
$(error unknown BOARD=$(BOARD); known: qemu-mps2 qemu-m4 teensy41 feather-nrf52840)
endif
ADDER   ?= ../adder
CLANG   ?= clang
LLD     ?= ld.lld
OBJDUMP ?= llvm-objdump
OBJCOPY ?= llvm-objcopy
SIZE    ?= llvm-size
QEMU    ?= qemu-system-arm

HOST_AC := $(ADDER)/build/cutover/host_ac.elf
HOST_AC_ABS = $(abspath $(HOST_AC))
TRIPLE  := thumbv7em-none-eabihf

ifeq ($(BOARD),qemu-mps2)
B := build
else
B := build/$(BOARD)
endif
# Defaults a board.mk may change.
#   CPU, FPU      clang's -mcpu/-mfpu.  The Adder target is the same
#                 (thumbv7em-none-eabihf) for the Cortex-M7 and the M4F.
#   SOFT_DOUBLE   1 when the FPU has no double precision (Cortex-M4F:
#                 fpv4-sp-d16): float64 arithmetic becomes calls to the
#                 __aeabi_d* helpers, which then come from
#                 third_party/llvm-compiler-rt-builtins (kernel and programs).
#   PROG_ABI      pie: a program is a PIE copied whole into RAM (default);
#                 rwpi: code and constants PC-relative (ROPI), data
#                 r9-relative (RWPI), so the kernel can run a program's code
#                 in place from flash and copy only its data (docs/porting.md).
#   PROGS_SKIP    programs not built for this board.
LINK_LD       := boards/$(BOARD_DIR)/link.ld
IMAGES        := hmicro
BOARD_PATCHES :=
PROG_AFLAGS   :=
CPU           := cortex-m7
FPU           := fpv5-d16
SOFT_DOUBLE   := 0
PROG_ABI      := pie
PROGS_SKIP    :=
BOARD_COBJS   :=
BOARD_SHT4X   := 0
include boards/$(BOARD_DIR)/board.mk
ifeq ($(BOARD_SHT4X),1)
COBJS_hmicro = $(COBJS_SHT4X)
endif

CPUFLAGS := --target=$(TRIPLE) -mcpu=$(CPU) -mfpu=$(FPU) -mfloat-abi=hard -mthumb
ifeq ($(CPU),cortex-m4)
CPUFLAGS += -DHMICRO_CPU_M4
endif
OPT     ?= -O2
# -ffunction-sections/-fdata-sections + --gc-sections: only what is reachable
# from the vector table is linked.
LLFLAGS := $(CPUFLAGS) $(OPT) -ffreestanding -fno-pic -ffunction-sections -fdata-sections -Wno-override-module
ASFLAGS := $(CPUFLAGS) -ffreestanding -Iboards/$(BOARD_DIR)
LDFLAGS := -T $(LINK_LD) --gc-sections -nostdlib -static $(LDFLAGS_BOARD)

# C code (third-party drivers and their tests): natural C ABI, no C library
# except lib/cshim, whose functions carry hmicro_c_ names (the forced include
# renames the usual ones; see lib/cshim/include/hmicro_libc_rename.h).
CFLAGS  := $(CPUFLAGS) $(OPT) -std=c11 -ffreestanding -nostdlibinc -fno-pic -ffunction-sections -fdata-sections \
           -Wall -Wextra -isystem lib/cshim/include -include lib/cshim/include/hmicro_libc_rename.h
C_SHT4X := third_party/sensirion-sht4x
COBJS_ktest := $(B)/c/sht4x_i2c.o $(B)/c/sensirion_i2c.o $(B)/c/sensirion_common.o $(B)/c/interop.o $(B)/c/libc.o
# The system image of a board whose devices.ad binds the SHT4x driver
# (BOARD_SHT4X := 1 in board.mk; drivers/i2c/sht4xfs.ad) links it too.
COBJS_SHT4X := $(B)/c/sht4x_i2c.o $(B)/c/sensirion_i2c.o $(B)/c/sensirion_common.o $(B)/c/libc.o
# C objects every image of a board links (BOARD_COBJS in board.mk): the
# glyph table of a board that has a display (drivers/display/font8x8.c).
C_FONT := third_party/font8x8

SRC_AD := $(wildcard drivers/display/*.c kernel/*.ad kernel/*/*.ad mm/*.ad fs/*.ad lib/*.ad lib/*/*.ad drivers/*/*.ad init/*.ad user/*.ad boards/*/*.ad soc/*/*.ad demo/*.ad tests/*.ad tests/*/*.ad)

# ---- user programs -----------------------------------------------------------
# Each is its own Adder translation unit, compiled position-independent and
# linked with the user run-time (user/rt/) into a PIE that the kernel loads
# from /bin.  $(B)/user/NAME.elf keeps its symbols; $(B)/user/NAME is the
# stripped file that goes into the image's ROM file table.
#   user/progs/NAME.ad    Hamnix Micro's own (tests, examples)
#   user/hamnix/NAME.ad   copied from Hamnix (fs/HAMNIX_ORIGIN)
# Per program: STACK_NAME (bytes of stack, default 8192) and HEAP_NAME
# (bytes of heap for sys_mmap, default 0).
PROGS_OWN    := hello help ptest crel halt regprobe sleep setdate suspend idlestat keypress exportfs srv
HEAP_ptest   := 8192
PROGS_HAMNIX := echo cat ls cp rm mkdir wc head grep hamsh mv touch tail sort uniq tr date df free ps kill od tee cut seq vi p9srv_demo
STACK_hamsh  ?= 65536
PROGS        := $(filter-out $(PROGS_SKIP),$(PROGS_OWN) $(PROGS_HAMNIX))
PROG_BINS    := $(PROGS:%=$(B)/user/%)
SRC_USER     := $(wildcard user/progs/*.ad user/hamnix/*.ad user/rt/*.ad lib/*.ad lib/*/*.ad kernel/rt.ad)
ifeq ($(PROG_ABI),rwpi)
UPIC    := -fropi -frwpi
UAFLAGS := $(CPUFLAGS) -ffreestanding -DHMICRO_RWPI
ULDFLAGS := -static -T user/rt/prog_rwpi.ld --gc-sections -nostdlib -z max-page-size=16 --no-rosegment
else
UPIC    := -fPIE
UAFLAGS := $(CPUFLAGS) -ffreestanding -fPIE
ULDFLAGS := -pie --no-dynamic-linker --omagic -T user/rt/prog.ld --gc-sections -nostdlib -z norelro
endif
UFLAGS  := $(CPUFLAGS) $(OPT) -ffreestanding $(UPIC) -ffunction-sections -fdata-sections -Wno-override-module
URT     := $(B)/user/crt.o $(B)/user/aeabi.o $(B)/user/rt.o

# Soft double precision (SOFT_DOUBLE=1): compiler-rt's builtins, unmodified,
# compiled twice: for the kernel (absolute) and for programs (as UPIC).
CRT_DIR  := third_party/llvm-compiler-rt-builtins/builtins
CRT_SRCS := adddf3 subdf3 muldf3 divdf3 comparedf2 fixdfsi fixunsdfsi floatsidf floatunsidf extendsfdf2 truncdfsf2
CRT_CFLAGS := $(CPUFLAGS) $(OPT) -std=c11 -ffreestanding -nostdlibinc -ffunction-sections -fdata-sections -DCOMPILER_RT_ARMHF_TARGET -w
ifeq ($(SOFT_DOUBLE),1)
KRT_OBJS := $(CRT_SRCS:%=$(B)/crt/k_%.o) $(B)/crt/k_aeabi_dcmp.o $(B)/crt/k_fp_mode.o
URT      += $(CRT_SRCS:%=$(B)/crt/u_%.o) $(B)/crt/u_aeabi_dcmp.o $(B)/crt/u_fp_mode.o
else
KRT_OBJS :=
endif
STRIP   ?= llvm-strip

.SECONDARY:
.PHONY: all test run size measure clean compiler test-teensy test-nrf52 test-m4
all: $(IMAGES:%=$(B)/%.elf) $(BOARD_ALL)

# Bootstrap the compiler in ITS tree if its binary is missing or older than
# its sources (the Python seed compiles the self-hosted compiler; ~7 s).
compiler: $(HOST_AC)
$(HOST_AC): $(wildcard $(ADDER)/adder/compiler/*.ad)
	cd $(ADDER) && bash -c 'source scripts/_adder_cc.sh && adder_cc_bootstrap' >/dev/null
	@test -x $@

$(B):
	mkdir -p $(B)

# The tree the compiler runs in (see the top of this file).
SRCROOT := $(B)/root/.stamp
$(SRCROOT): $(SRC_AD) $(SRC_USER) $(BOARD_PATCHES) scripts/mkroot.sh boards/$(BOARD_DIR)/board.mk | $(B)
	bash scripts/mkroot.sh $(B)/root $(BOARD_DIR) $(BOARD_PATCHES)

# One Adder translation unit per image: the root file plus its import closure.
# The compiler resolves imports relative to the current directory, so it runs
# from the firmware root.  A function outside the LLVM-lane subset is a hard
# compile error on this target.
$(B)/%.ll: $(SRC_AD) $(HOST_AC) $(SRCROOT) | $(B)
	cd $(B)/root && $(HOST_AC_ABS) --backend=llvm --target=$(TRIPLE) $(ROOT_$*) $(abspath $@)
	@grep '^; ADDER_STAT' $@

ROOT_hmicro := init/main.ad
ROOT_monitor := init/monitor_main.ad
KOBJS_monitor := $(B)/switch.o
ROOT_selftest := demo/main.ad
KOBJS_hmicro := $(B)/switch.o
ROOT_ktest := tests/ktest_main.ad
KOBJS_ktest := $(B)/switch.o $(B)/fptest.o
ROOT_faulttest := tests/fault_main.ad

$(B)/%.o: $(B)/%.ll
	$(CLANG) $(LLFLAGS) -c $< -o $@

$(B)/user:
	mkdir -p $(B)/user

$(B)/user/rt.ll: user/rt/rt.ad kernel/rt.ad $(HOST_AC) $(SRCROOT) | $(B)/user
	cd $(B)/root && $(HOST_AC_ABS) --backend=llvm --target=$(TRIPLE) $(PROG_AFLAGS) $< $(abspath $@)

$(B)/user/%.ll: user/progs/%.ad $(SRC_USER) $(HOST_AC) $(SRCROOT) | $(B)/user
	cd $(B)/root && $(HOST_AC_ABS) --backend=llvm --target=$(TRIPLE) $(PROG_AFLAGS) $< $(abspath $@)

$(B)/user/%.ll: user/hamnix/%.ad $(SRC_USER) $(HOST_AC) $(SRCROOT) | $(B)/user
	cd $(B)/root && $(HOST_AC_ABS) --backend=llvm --target=$(TRIPLE) $(PROG_AFLAGS) $< $(abspath $@)

$(B)/user/%.o: $(B)/user/%.ll
	$(CLANG) $(UFLAGS) -c $< -o $@

# A C program: natural C code, position-independent, no C library.
$(B)/user/%.o: user/progs/%.c | $(B)/user
	$(CLANG) $(CPUFLAGS) $(OPT) -std=c11 -ffreestanding -nostdlibinc $(UPIC) -ffunction-sections -fdata-sections -Wall -Wextra -c $< -o $@

# An assembly program that is its own entry point (no run-time linked in).
$(B)/user/regprobe.o: user/progs/regprobe.S | $(B)/user
	$(CLANG) $(UAFLAGS) -c $< -o $@

$(B)/user/regprobe.elf: $(B)/user/regprobe.o user/rt/prog.ld user/rt/prog_rwpi.ld
	$(LLD) $(ULDFLAGS) -z stack-size=1024 --defsym=__heap_size=0 -Map=$(B)/user/regprobe.map -o $@ $<

$(B)/user/crt.o: user/rt/crt.S | $(B)/user
	$(CLANG) $(UAFLAGS) -c $< -o $@

$(B)/user/aeabi.o: arch/armv7m/aeabi.S | $(B)/user
	$(CLANG) $(UAFLAGS) -c $< -o $@

$(B)/crt:
	mkdir -p $(B)/crt

$(B)/crt/k_%.o: $(CRT_DIR)/%.c | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) -fno-pic -c $< -o $@

$(B)/crt/u_%.o: $(CRT_DIR)/%.c | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) $(UPIC) -c $< -o $@

$(B)/crt/k_fp_mode.o: $(CRT_DIR)/arm/fp_mode.c | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) -fno-pic -c $< -o $@

$(B)/crt/u_fp_mode.o: $(CRT_DIR)/arm/fp_mode.c | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) $(UPIC) -c $< -o $@

$(B)/crt/k_aeabi_dcmp.o: $(CRT_DIR)/arm/aeabi_dcmp.S | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) -c $< -o $@

$(B)/crt/u_aeabi_dcmp.o: $(CRT_DIR)/arm/aeabi_dcmp.S | $(B)/crt
	$(CLANG) $(CRT_CFLAGS) -c $< -o $@

$(B)/user/%.elf: $(B)/user/%.o $(URT) user/rt/prog.ld user/rt/prog_rwpi.ld
	$(LLD) $(ULDFLAGS) -z stack-size=$(or $(STACK_$*),$(STACK_DEFAULT_BOARD),8192) --defsym=__heap_size=$(or $(HEAP_$*),0) -Map=$(B)/user/$*.map -o $@ $(URT) $<

$(B)/user/%: $(B)/user/%.elf
	$(STRIP) --strip-all -o $@ $<

# The ROM file table: every program, under /bin.
$(B)/romfs.S: $(PROG_BINS) scripts/mkromfs.sh
	bash scripts/mkromfs.sh $@ $(PROG_BINS)

$(B)/romfs.o: $(B)/romfs.S
	$(CLANG) $(ASFLAGS) -c $< -o $@

$(B)/%.o: arch/armv7m/%.S | $(B)
	$(CLANG) $(ASFLAGS) -c $< -o $@

$(B)/startup.o: boards/$(BOARD_DIR)/vectors.S

$(B)/c/%.o: $(C_SHT4X)/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -I$(C_SHT4X) -c $< -o $@

$(B)/c/font8x8.o: drivers/display/font8x8.c $(C_FONT)/font8x8_basic.h | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -I$(C_FONT) -c $< -o $@

$(B)/c/%.o: tests/c/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -c $< -o $@

$(B)/c/%.o: lib/cshim/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -c $< -o $@

$(B)/%.o: tests/arch/%.S | $(B)
	$(CLANG) $(ASFLAGS) -c $< -o $@

$(B)/%.elf: $(B)/%.o $(B)/startup.o $(B)/aeabi.o $(B)/cpu.o $(B)/switch.o $(B)/romfs.o $(KRT_OBJS) $(foreach i,$(IMAGES),$(KOBJS_$(i)) $(COBJS_$(i))) $(BOARD_COBJS) $(LINK_LD)
	$(LLD) $(LDFLAGS) -Map=$(B)/$*.map -o $@ $(B)/startup.o $(B)/aeabi.o $(B)/cpu.o $(KOBJS_$*) $(COBJS_$*) $(BOARD_COBJS) $(B)/romfs.o $(KRT_OBJS) $<
	$(OBJDUMP) -d --mcpu=$(CPU) --no-show-raw-insn $@ > $(B)/$*.lst

# The "card": a 2 MiB FAT32 image made with mtools, loaded by QEMU into the
# RAM disk (boards/mps2_an500/link.ld: __ramdisk_start) before the kernel
# starts.  512-byte clusters; a file with a long name, a file that spans many
# clusters, a sub-directory.  Without mtools there is no image and no /sd.
SD_ADDR := 0x20200000
$(B)/sd.img: tests/sd/readme.txt $(B)/user/hello | $(B)
	rm -f $@ && truncate -s 2M $@
	mformat -i $@ -F -c 1 -v HMICRO ::
	mcopy -i $@ tests/sd/readme.txt ::README.TXT
	mcopy -i $@ tests/sd/readme.txt "::A long file name.text"
	mmd -i $@ ::DOCS
	mcopy -i $@ $(B)/user/hello ::DOCS/HELLO
	python3 -c "import sys; sys.stdout.buffer.write(bytes((i * 7 + 3) & 255 for i in range(40000)))" > $(B)/pattern.bin
	mcopy -i $@ $(B)/pattern.bin ::PATTERN.BIN

# Flash image for the Teensy loader (Intel HEX at the flash addresses) and
# the raw image from 0x60000000 (what tests/imxrt/check_boot.py reads).
$(B)/hmicro.hex: $(B)/hmicro.elf
	$(OBJCOPY) -O ihex $< $@

$(B)/hmicro.bin: $(B)/hmicro.elf
	$(OBJCOPY) -O binary $< $@

# UF2 for the Adafruit nRF52 bootloader's drag-and-drop drive
# (scripts/mkuf2.py; tests/nrf52/check_uf2.py checks the result).
$(B)/hmicro.uf2: $(B)/hmicro.hex scripts/mkuf2.py
	python3 -I scripts/mkuf2.py --family $(UF2_FAMILY) $< $@

# The nRF52840 checks that need no board, the Renode run included
# (tests/nrf52/run_all.sh).
test-nrf52:
	$(MAKE) BOARD=feather-nrf52840 ADDER=$(ADDER)
	ADDER=$(ADDER) bash tests/nrf52/run_all.sh

# The kernel tests and the shell session on QEMU's Cortex-M4F machine
# (tests/m4/run_all.sh).
test-m4:
	$(MAKE) BOARD=qemu-m4 ADDER=$(ADDER) build/qemu-m4/hmicro.elf build/qemu-m4/ktest.elf build/qemu-m4/sd.img
	ADDER=$(ADDER) bash tests/m4/run_all.sh

# The checks of the i.MX RT code that need no board (tests/imxrt/README).
test-teensy:
	$(MAKE) BOARD=teensy41 ADDER=$(ADDER)
	ADDER=$(ADDER) bash tests/imxrt/run_all.sh

run: $(B)/hmicro.elf $(B)/sd.img
	$(QEMU) -M mps2-an500 -nographic -no-reboot -device loader,file=$(B)/sd.img,addr=$(SD_ADDR) -kernel $<

size: $(B)/hmicro.elf
	$(SIZE) $<

test: $(B)/hmicro.elf $(B)/monitor.elf $(B)/ktest.elf $(B)/selftest.elf $(B)/faulttest.elf $(B)/sd.img
	ADDER=$(ADDER) bash tests/run_all.sh

measure: $(HOST_AC)
	ADDER=$(ADDER) bash tests/measure.sh

clean:
	rm -rf $(B)
