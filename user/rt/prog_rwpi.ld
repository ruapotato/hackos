/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- layout of a user program for PROG_ABI=rwpi (boards without RAM
 * for whole programs: BOARD=feather-nrf52840).
 *
 * Compiled with `-fropi -frwpi`: code and read-only data are reached
 * PC-relative (ROPI), writable data relative to r9, the static base (RWPI).
 * So the two halves can be put in different places:
 *
 *   segment 1, R+X, linked at 0:          .text, .rodata
 *   segment 2, R+W, linked at 0x40000000: .data, .bss, the heap
 *
 * The kernel (kernel/proc.ad) runs segment 1 IN PLACE when the file is in
 * the ROM table (flash, /bin), or copies it into the process block
 * otherwise, copies segment 2's file part into the block, clears the rest,
 * and starts the program with r9 = where segment 2 went.  lld resolves
 * every r9-relative reference against the first section of segment 2 (its
 * "static base").  0x40000000 is only a marker that keeps the two halves'
 * link addresses apart; nothing ever runs there.
 *
 * No relocations are applied at load time: a pointer stored in initialised
 * data (R_ARM_ABS32) would need one, and the Makefile's check refuses such
 * a program (none of HackOS's or Hamnix's programs has one).
 * The stack travels in PT_GNU_STACK as for a PIE (`-z stack-size=N`).     */
ENTRY(hackos_crt_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
    stack PT_GNU_STACK FLAGS(6);
}

SECTIONS
{
    . = 0;
    .text : ALIGN(8) { *(.text.hackos_crt_start) *(.text .text.*) } :text
    .rodata : ALIGN(8) { *(.rodata .rodata.*) } :text
    . = 0x40000000;
    .data : ALIGN(8) { *(.data.rel.ro .data.rel.ro.*) *(.data .data.*) } :data
    .bss (NOLOAD) : ALIGN(8)
    {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __heap_start = .;
        . = . + __heap_size;
        __heap_end = .;
    } :data
    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .ARM.attributes .comment .note* .interp .got .got.plt .dynamic .dynsym .dynstr .hash .gnu.hash .rel.dyn) }
}
