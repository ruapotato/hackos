/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* uSDHC test image for QEMU mcimx6ul-evk: everything in its DDR at
 * 0x80000000 (QEMU loads the ELF segments there; .data needs no copy). */
ENTRY(_entry)
SECTIONS
{
    . = 0x80000000;
    .text : { KEEP(*(.text.entry)) *(.text .text.*) *(.rodata .rodata.*) }
    .data : ALIGN(8) { *(.data .data.*) }
    .bss : ALIGN(8) { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(16);
    . = . + 0x10000;
    __stack_top = .;
    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .comment .note*) }
}
