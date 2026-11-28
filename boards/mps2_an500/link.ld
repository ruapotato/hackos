/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- linker script for QEMU `-M mps2-an500` (ARM MPS2, AN500, Cortex-M7).
 *
 * Memory map, checked two ways (2026-11-26, QEMU 10.0.13):
 *   - `info mtree -f` on the running machine:
 *       0x00000000-0x003fffff ram  mps.ssram1     (aliased again at 0x00400000)
 *       0x20000000-0x203fffff ram  mps.ssram23    (aliased again at 0x20400000)
 *       0x21000000-0x21ffffff i/o  PSRAM          (NOT memory: an unimplemented-
 *                                                  device stub in this QEMU)
 *       0x60000000-0x60ffffff ram  mps.ram        (16 MB)
 *   - hw/arm/mps2.c: armv7m_load_kernel(cpu, kernel, 0, 0x400000).
 * The "flash" of this FPGA image is RAM (SSRAM1); QEMU loads the ELF's
 * segments at their load addresses and takes MSP/PC from the table at 0.
 * .data is still given a separate load address (LMA in CODE, VMA in RAM) and
 * copied by the start-up code, so the same layout works on a real ROM.
 *
 * Layout (the MPU plan in kernel/mpu.ad depends on these alignments):
 *   CODE 0x00000000  boot vectors (reset only), then nothing up to 0x1000:
 *                    the first 4 KB are an MPU no-access region, so a null
 *                    pointer dereference faults.  Vector table, text and
 *                    read-only data follow from 0x1000 (VTOR is set there).
 *   RAM  0x20000000  kernel .data/.bss, handler (MSP) stack, fault stack.
 *   XRAM 0x60000000  large kernel tables (.bss of the file system), then the
 *                    kernel heap up to __prog_start (4 MB in all);
 *                    then the program arena (11 MB): one block per process,
 *                    each opened to its own process only by an MPU region;
 *                    the last 1 MB is the shared arena of the unprivileged
 *                    threads that are compiled into the kernel image (tests):
 *                    their stacks and mmap memory.  __user_start must be a
 *                    multiple of the shared arena's size.
 *
 * On the i.MX RT117x target the same three roles map to flash (XIP), DTCM/OCRAM
 * and the 64 MB SDRAM.
 */
ENTRY(Reset_Handler)

MEMORY
{
    CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
    XRAM (rwx) : ORIGIN = 0x60000000, LENGTH = 16M
}

__stack_size = 0x4000;          /* handler-mode (MSP) stack */
__user_size  = 0x100000;        /* shared user arena: 1 MB, MPU region aligned */
__prog_size  = 0xB00000;        /* program arena: 11 MB */
__null_guard_size = 0x1000;

SECTIONS
{
    .boot :
    {
        KEEP(*(.boot_vectors))
        . = __null_guard_size;
    } > CODE

    .text :
    {
        __vectors_start = .;
        KEEP(*(.vectors))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(8);
        __text_end = .;
    } > CODE

    /* No unwinder: these must stay empty (functions are `nounwind`). */
    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .ARM.attributes .comment .note*) }

    __data_load = LOADADDR(.data);
    .data : ALIGN(8)
    {
        __data_start = .;
        *(.data .data.*)
        . = ALIGN(8);
        __data_end = .;
    } > RAM AT > CODE

    /* Large zero-initialised tables go to the 16 MB region; everything else
     * stays in the 4 MB kernel RAM.  Adder has no section attribute, so the
     * tables are named here (each global has its own section because the
     * image is compiled with -fdata-sections). */
    .xbss (NOLOAD) : ALIGN(8)
    {
        __xbss_start = .;
        *(.bss.tmpfs_table)
        . = ALIGN(8);
        __xbss_end = .;
    } > XRAM

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(8)
    {
        __stack_bottom = .;
        . = . + __stack_size;
        __stack_top = .;
    } > RAM

    .fault_stack (NOLOAD) : ALIGN(8)
    {
        . = . + 0x800;
        __fault_stack_top = .;
    } > RAM
    __ram_end = ORIGIN(RAM) + LENGTH(RAM);

    /* The RAM disk ("ram0", kernel/block/blk.ad): the upper half of the
     * kernel RAM region, which the kernel's own data does not come near.
     * The test harness has QEMU load a FAT32 image here (-device loader). */
    __ramdisk_start = ORIGIN(RAM) + 0x200000;
    __ramdisk_size = 0x200000;
    ASSERT(__fault_stack_top <= __ramdisk_start, "kernel data runs into the RAM disk")

    __user_end = ORIGIN(XRAM) + LENGTH(XRAM);
    __user_start = __user_end - __user_size;
    __heap_start = ALIGN(__xbss_end, 16);
    __prog_end = __user_start;
    __prog_start = __prog_end - __prog_size;
    __heap_end = __prog_start;
}
