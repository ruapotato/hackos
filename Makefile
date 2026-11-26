# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# HackOS -- build and test (milestone 1: QEMU mps2-an500, ARM Cortex-M7).
#
#   make            build build/hackos.elf (the demo / self-test image)
#   make test       build everything from source and run every test; non-zero
#                   exit status on any failure
#   make run        run the demo in QEMU with the UART on the terminal
#   make size       text/data/bss of the image
#   make measure    cost of the i64 value model vs. C (tests/measure.sh)
#
# ADDER points at a checkout of the Adder compiler that has the
# thumbv7em-none-eabihf target (branch cortex-m7).  Nothing from that tree is
# copied here; its host compiler binary is bootstrapped there on first use.
ADDER   ?= ../adder
CLANG   ?= clang
LLD     ?= ld.lld
OBJDUMP ?= llvm-objdump
OBJCOPY ?= llvm-objcopy
SIZE    ?= llvm-size
QEMU    ?= qemu-system-arm

HOST_AC := $(ADDER)/build/cutover/host_ac.elf
TRIPLE  := thumbv7em-none-eabihf
CPUFLAGS := --target=$(TRIPLE) -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -mthumb
OPT     ?= -O2
# -ffunction-sections/-fdata-sections + --gc-sections: only what is reachable
# from the vector table is linked.
LLFLAGS := $(CPUFLAGS) $(OPT) -ffreestanding -fno-pic -ffunction-sections -fdata-sections -Wno-override-module
ASFLAGS := $(CPUFLAGS) -ffreestanding
LDFLAGS := -T boards/mps2_an500/link.ld --gc-sections -nostdlib -static

B := build

# C code (third-party drivers and their tests): natural C ABI, no C library
# except lib/cshim, whose functions carry hackos_c_ names (the forced include
# renames the usual ones; see lib/cshim/include/hackos_libc_rename.h).
CFLAGS  := $(CPUFLAGS) $(OPT) -std=c11 -ffreestanding -nostdlibinc -fno-pic -ffunction-sections -fdata-sections \
           -Wall -Wextra -isystem lib/cshim/include -include lib/cshim/include/hackos_libc_rename.h
C_SHT4X := third_party/sensirion-sht4x
COBJS_ktest := $(B)/c/sht4x_i2c.o $(B)/c/sensirion_i2c.o $(B)/c/sensirion_common.o $(B)/c/interop.o $(B)/c/libc.o

SRC_AD := $(wildcard kernel/*.ad kernel/*/*.ad mm/*.ad fs/*.ad lib/*.ad lib/*/*.ad drivers/*/*.ad init/*.ad user/*.ad boards/mps2_an500/*.ad demo/*.ad tests/*.ad tests/*/*.ad)

.SECONDARY:
.PHONY: all test run size measure clean compiler
all: $(B)/hackos.elf

# Bootstrap the compiler in ITS tree if its binary is missing or older than
# its sources (the Python seed compiles the self-hosted compiler; ~7 s).
compiler: $(HOST_AC)
$(HOST_AC): $(wildcard $(ADDER)/adder/compiler/*.ad)
	cd $(ADDER) && bash -c 'source scripts/_adder_cc.sh && adder_cc_bootstrap' >/dev/null
	@test -x $@

$(B):
	mkdir -p $(B)

# One Adder translation unit per image: the root file plus its import closure.
# The compiler resolves imports relative to the current directory, so it runs
# from the firmware root.  A function outside the LLVM-lane subset is a hard
# compile error on this target.
$(B)/%.ll: $(SRC_AD) $(HOST_AC) | $(B)
	$(HOST_AC) --backend=llvm --target=$(TRIPLE) $(ROOT_$*) $@
	@grep '^; ADDER_STAT' $@

ROOT_hackos := init/main.ad
ROOT_selftest := demo/main.ad
KOBJS_hackos := $(B)/switch.o
ROOT_ktest := tests/ktest_main.ad
KOBJS_ktest := $(B)/switch.o $(B)/fptest.o
ROOT_faulttest := tests/fault_main.ad

$(B)/%.o: $(B)/%.ll
	$(CLANG) $(LLFLAGS) -c $< -o $@

$(B)/%.o: arch/armv7m/%.S | $(B)
	$(CLANG) $(ASFLAGS) -c $< -o $@

$(B)/c/%.o: $(C_SHT4X)/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -I$(C_SHT4X) -c $< -o $@

$(B)/c/%.o: tests/c/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -c $< -o $@

$(B)/c/%.o: lib/cshim/%.c | $(B)
	@mkdir -p $(B)/c
	$(CLANG) $(CFLAGS) -c $< -o $@

$(B)/%.o: tests/arch/%.S | $(B)
	$(CLANG) $(ASFLAGS) -c $< -o $@

$(B)/%.elf: $(B)/%.o $(B)/startup.o $(B)/cpu.o $(B)/switch.o $(B)/fptest.o $(COBJS_ktest) boards/mps2_an500/link.ld
	$(LLD) $(LDFLAGS) -Map=$(B)/$*.map -o $@ $(B)/startup.o $(B)/cpu.o $(KOBJS_$*) $(COBJS_$*) $<
	$(OBJDUMP) -d --mcpu=cortex-m7 --no-show-raw-insn $@ > $(B)/$*.lst

run: $(B)/hackos.elf
	$(QEMU) -M mps2-an500 -nographic -semihosting-config enable=on,target=native -kernel $<

size: $(B)/hackos.elf
	$(SIZE) $<

test: $(B)/hackos.elf $(B)/ktest.elf $(B)/selftest.elf $(B)/faulttest.elf
	ADDER=$(ADDER) bash tests/run_all.sh

measure: $(HOST_AC)
	ADDER=$(ADDER) bash tests/measure.sh

clean:
	rm -rf $(B)
