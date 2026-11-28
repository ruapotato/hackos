/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- linker script for the Teensy 4.1 (NXP i.MX RT1062).
 * UNTESTED ON HARDWARE.
 *
 * Memory (RT1060 reference manual, system memory map; PJRC's
 * imxrt1062_t41.ld uses the same addresses):
 *   FLASH 0x60000000  8 MiB W25Q64JV on FlexSPI, executed in place.  PJRC
 *                     keeps the last 256 KB for its EEPROM emulation and the
 *                     restore program, so an image may use 7936 KB.
 *   ITCM  0x00000000  FlexRAM bank 0 (32 KB).  Nothing is linked there: its
 *                     first 4 KB are the MPU's null-pointer guard, the rest
 *                     is free for later.
 *   DTCM  0x20000000  FlexRAM banks 1-9 (288 KB), zero wait states, not
 *                     executable (the M7 does not fetch from DTCM), not
 *                     cached: kernel data, stacks, kernel heap.
 *   OCRAM 0x20200000  512 KB of on-chip RAM (OCRAM2 in the manual) and, right
 *                     after it at 0x20280000, FlexRAM banks 10-15 configured
 *                     as OCRAM (192 KB): 704 KB, contiguous, on the AXI bus,
 *                     executable: the program arena.  Programs run from here,
 *                     so it is the only place a process can live.  (NXP's
 *                     own MIMXRT1062xxxxx_flexspi_nor.ld treats 0x20200000 +
 *                     768 KB as one region for the default FlexRAM split.)
 * The 512 KB FlexRAM split is __flexram_bank_config below, written to
 * IOMUXC_GPR_GPR17 by board_reset_early (vectors.S): 2 bits per 32 KB bank,
 * 11 ITCM, 10 DTCM, 01 OCRAM.  PJRC's start-up uses only ITCM and DTCM
 * banks; OCRAM banks are the fuse default's third kind (the reset default
 * is 128 KB ITCM, 128 KB DTCM, 256 KB OCRAM).
 *
 * Optional PSRAM (FlexSPI2, 0x70000000) is not used: nothing configures
 * FlexSPI2, and the MPU makes that window no-access (board.ad).
 *
 * Section and symbol names are those of boards/mps2_an500/link.ld, which
 * the kernel relies on.                                                  */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x60000000, LENGTH = 7936K
    ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
    DTCM (rw)  : ORIGIN = 0x20000000, LENGTH = 288K
    OCRAM (rwx): ORIGIN = 0x20200000, LENGTH = 704K
}

__flexram_bank_config = 0x555AAAAB;  /* bank 0 ITCM (11), 1-9 DTCM (10), 10-15 OCRAM (01) */
/* Why this split: the shell is a 448 KB block that must start on a 512 KB
 * boundary (0x20200000); grep, the largest other program, a 192 KB block on
 * a 256 KB boundary (0x20280000); 704 KB holds both.  Every further bank of
 * DTCM is kernel heap, which also holds the data of files in / (tmpfs).
 * tests/imxrt/t41mem.sh runs the shell session in exactly this map. */
__stack_size = 0x4000;               /* handler-mode (MSP) stack */
__user_size  = 0x4000;               /* shared arena of in-image unprivileged
                                        threads: 16 KB, none in this image */

SECTIONS
{
    /* Boot header: FCB at the start of flash, IVT and boot data at 4 KB. */
    .boot :
    {
        KEEP(*(.flashconfig))
        FILL(0xFF)
        . = ORIGIN(FLASH) + 0x1000;
        KEEP(*(.ivt))
        . = ORIGIN(FLASH) + 0x1020;
        KEEP(*(.bootdata))
        . = ORIGIN(FLASH) + 0x2000;
    } > FLASH

    .text :
    {
        __vectors_start = .;
        KEEP(*(.vectors))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(8);
        __text_end = .;
    } > FLASH

    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .ARM.attributes .comment .note*) }

    __data_load = LOADADDR(.data);
    .data : ALIGN(8)
    {
        __data_start = .;
        *(.data .data.*)
        . = ALIGN(8);
        __data_end = .;
    } > DTCM AT > FLASH

    /* No separate large RAM on this board: the file-system table lives in
     * DTCM with the rest (the section is kept so the image has the same
     * shape as on the other boards). */
    .xbss (NOLOAD) : ALIGN(8)
    {
        __xbss_start = .;
        *(.bss.tmpfs_table)
        . = ALIGN(8);
        __xbss_end = .;
    } > DTCM

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DTCM

    .stack (NOLOAD) : ALIGN(8)
    {
        __stack_bottom = .;
        . = . + __stack_size;
        __stack_top = .;
    } > DTCM

    .fault_stack (NOLOAD) : ALIGN(8)
    {
        . = . + 0x800;
        __fault_stack_top = .;
    } > DTCM

    __flash_end = LOADADDR(.data) + SIZEOF(.data);
    __flash_image_len = ALIGN(__flash_end - ORIGIN(FLASH), 1024);
    __ram_end = ORIGIN(DTCM) + LENGTH(DTCM);

    /* .bss is cleared by hmicro_start, .xbss is not: on the mps2 board
     * that table is in memory QEMU zeroes.  Here it must be inside the
     * cleared range, so .xbss directly precedes .bss and the start-up code
     * clears from __xbss_start (see board_init_early). */

    /* the shared user arena at the top of DTCM (aligned to its size, as
     * MPU region 4 requires), the kernel heap between the stacks and it */
    __user_end = __ram_end;
    __user_start = __user_end - __user_size;
    __heap_start = ALIGN(__fault_stack_top, 16);
    __heap_end = __user_start;
    ASSERT(__heap_end > __heap_start + 0x10000, "less than 64 KB of DTCM left for the kernel heap")
    ASSERT(__user_start % __user_size == 0, "the shared user arena is not aligned to its size")

    /* the program arena: all of OCRAM (OCRAM2 + the FlexRAM OCRAM banks) */
    __prog_start = ORIGIN(OCRAM);
    __prog_end = ORIGIN(OCRAM) + LENGTH(OCRAM);

    /* no RAM disk: /sd is the microSD card (board.ad) */
    __ramdisk_start = 0;
    __ramdisk_size = 0;

    ASSERT(ADDR(.boot) == 0x60000000, "the FCB must be at the start of flash")
    ASSERT(__vectors_start % 1024 == 0, "the vector table must be 1 KB aligned")
    ASSERT(__flash_end <= ORIGIN(FLASH) + LENGTH(FLASH), "image larger than 7936 KB")
}
