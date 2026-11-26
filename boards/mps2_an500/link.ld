/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- linker script for QEMU `-M mps2-an500` (ARM MPS2, AN500, Cortex-M7).
 *
 * Memory map, checked two ways (2026-11-26, QEMU 10.0.13):
 *   - `info mtree -f` on the running machine;
 *   - hw/arm/mps2.c: "0x00000000 .. 0x003fffff : ZBT SSRAM1",
 *     "0x20000000 .. 0x203fffff : ZBT SSRAM 2&3", and
 *     armv7m_load_kernel(cpu, kernel, 0, 0x400000).
 * The "flash" of this FPGA image is RAM (SSRAM1); QEMU loads the ELF's
 * segments at their load addresses and takes MSP/PC from the table at 0.
 * .data is still given a separate load address (LMA in CODE, VMA in RAM) and
 * copied by the start-up code, so the same layout works on a real ROM.
 */
ENTRY(Reset_Handler)

MEMORY
{
    CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
}

__stack_size = 0x4000;

SECTIONS
{
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

    __heap_start = .;
    __heap_end = ORIGIN(RAM) + LENGTH(RAM);
}
