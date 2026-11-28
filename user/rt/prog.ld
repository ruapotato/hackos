/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- layout of a user program (position-independent executable).
 *
 * Linked at address 0 with `ld.lld -pie --omagic`; the kernel's loader
 * (kernel/proc.ad) copies the image to wherever its block of the program
 * arena is and applies the R_ARM_RELATIVE entries of .rel.dyn.  --omagic
 * makes everything one read/write/execute load segment, packed without page
 * alignment: on a machine without an MMU a page boundary inside a program
 * buys nothing and costs memory (and 64 KiB of padding in the file).
 *
 * The stack is NOT part of the image: its size travels in the PT_GNU_STACK
 * header (`-z stack-size=N`) and the loader puts it below the image.
 * The heap IS part of the image: __heap_size bytes after .bss, handed out by
 * user/rt/rt.ad's sys_mmap.  The link must define it (--defsym=__heap_size=N;
 * the Makefile passes 0 unless HEAP_<program> is set).
 */
ENTRY(hmicro_crt_start)

SECTIONS
{
    . = 0;
    .text : { *(.text.hmicro_crt_start) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .hash : { *(.hash) }
    .gnu.hash : { *(.gnu.hash) }
    .rel.dyn : ALIGN(4) { *(.rel.dyn) *(.rel.*) }
    .dynamic : ALIGN(4) { *(.dynamic) }
    .got : ALIGN(4) { *(.got) *(.got.*) }
    .data : ALIGN(8) { *(.data.rel.ro .data.rel.ro.*) *(.data .data.*) }
    .bss (NOLOAD) : ALIGN(8)
    {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __heap_start = .;
        . = . + __heap_size;
        __heap_end = .;
    }
    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .ARM.attributes .comment .note* .interp) }
}
