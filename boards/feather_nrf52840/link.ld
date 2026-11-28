/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- linker script for the Adafruit Feather nRF52840 Express
 * (Nordic nRF52840).  UNTESTED ON HARDWARE.
 *
 * Flash (1 MB at 0), as Adafruit's UF2 bootloader lays it out
 * (Adafruit_nRF52_Bootloader: linker/nrf52840.ld, dfu_types.h, uf2cfg.h,
 * CMakeLists.txt):
 *   0x00000000  MBR (4 KB)                      never written by a UF2 copy
 *   0x00001000  SoftDevice S140 6.1.1           kept: Hamnix Micro does not use it,
 *                                               the bootloader's BLE DFU does
 *   0x00026000  APPLICATION = this image        __app_start (board.mk)
 *   0x000AD000  __uf2_limit: Adafruit's bootloader 0.2.6 (2018, shipped on
 *               early boards) SILENTLY DROPS UF2 blocks at or above this
 *               address.  Found on the first real board: the image then
 *               ended at 0xBD000, so the end of /bin and all of .data's
 *               initial values stayed erased flash (0xFF) and the first
 *               use of an initialised global faulted.  The whole image
 *               must end below it (asserted below, and check_image.py).
 *   0x000EA000  application data (40 KB, CircuitPython/Arduino file system;
 *               USER_FLASH_END of later bootloaders)
 *   0x000F4000  bootloader, 0x000FE000 MBR parameters, 0x000FF000 settings
 * In the application area:
 *   __app_start  vector table, kernel code and constants
 *   0x00060000   /bin: the ROM file table, on a 128 KB boundary
 *                (programs' code runs from here in place, so the MPU opens
 *                this window, and only this, read-only to processes;
 *                board.ad board_mpu_xip_*)
 *   then .data's initial values
 *
 * RAM (256 KB at 0x20000000; the code bus alias at 0x00800000 is not used).
 * The bootloader keeps nothing in RAM an application must preserve (its
 * double-reset word at 0x20007F7C is only read during its own 500 ms
 * window); the MBR's forwarding word at 0x20000000 is unused because VTOR
 * points at this image's table.  Layout:
 *   0x20000000   .data, .bss (the tmpfs table first, .xbss), MSP stack,
 *                fault stack, kernel heap (kernel stacks, pipe buffers,
 *                tmpfs file data), the 256-byte shared user arena
 *   __prog_start the program arena up to the end of RAM: one MPU block per
 *                process (stack + data; code stays in flash)
 * __prog_start is chosen so that the shell's block (k/8 of a 128 KB region)
 * starts on its 128 KB boundary at 0x20020000 and the programs of a
 * pipeline fit below and above it (docs/boards/feather-nrf52840.md, memory).
 *
 * Section and symbol names are those of boards/mps2_an500/link.ld, which
 * the kernel relies on.                                                   */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x00026000, LENGTH = 0x000EA000 - 0x00026000
    RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}

__romfs_window = 0x00060000;
__uf2_limit = 0x000AD000;             /* bootloader 0.2.6 drops UF2 blocks from here on */
__prog_start = 0x20018000;
__stack_size = 0x2000;               /* handler-mode (MSP) stack */
__user_size  = 0x100;                /* shared arena of in-image unprivileged
                                        threads: none in this image */

/* Explicit program headers, without FILEHDR/PHDRS: otherwise lld puts the
 * ELF and program headers in a load segment below the first section (at
 * 0x20000, inside the SoftDevice), which a debugger that programs an ELF by
 * its segments would write.  tests/nrf52/check_image.py checks the segments. */
PHDRS
{
    text  PT_LOAD;
    romfs PT_LOAD;
    data  PT_LOAD;
    ram   PT_LOAD;
}

SECTIONS
{
    .text :
    {
        __vectors_start = .;
        KEEP(*(.vectors))
        *(.text .text.*)
        *(EXCLUDE_FILE(*romfs.o) .rodata EXCLUDE_FILE(*romfs.o) .rodata.*)
        . = ALIGN(8);
        __text_end = .;
    } > FLASH :text

    .romfs __romfs_window :
    {
        __romfs_start = .;
        KEEP(*romfs.o(.rodata .rodata.*))
        . = ALIGN(8);
        __romfs_end = .;
    } > FLASH :romfs

    /DISCARD/ : { *(.ARM.exidx* .ARM.extab* .ARM.attributes .comment .note*) }

    __data_load = LOADADDR(.data);
    .data : ALIGN(8)
    {
        __data_start = .;
        *(.data .data.*)
        . = ALIGN(8);
        __data_end = .;
    } > RAM AT > FLASH :data

    /* .xbss directly precedes .bss; board_init_early clears it (only QEMU
     * hands over zeroed RAM). */
    .xbss (NOLOAD) : ALIGN(8)
    {
        __xbss_start = .;
        *(.bss.tmpfs_table)
        . = ALIGN(8);
        __xbss_end = .;
    } > RAM :ram

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM :ram

    .stack (NOLOAD) : ALIGN(8)
    {
        __stack_bottom = .;
        . = . + __stack_size;
        __stack_top = .;
    } > RAM :ram

    .fault_stack (NOLOAD) : ALIGN(8)
    {
        . = . + 0x800;
        __fault_stack_top = .;
    } > RAM :ram

    __flash_end = LOADADDR(.data) + SIZEOF(.data);
    __ram_end = ORIGIN(RAM) + LENGTH(RAM);

    __user_end = __prog_start;
    __user_start = __user_end - __user_size;
    __heap_start = ALIGN(__fault_stack_top, 16);
    __heap_end = __user_start;
    __prog_end = __ram_end;

    /* no RAM disk, no card: no /sd on this board */
    __ramdisk_start = 0;
    __ramdisk_size = 0;

    ASSERT(__app_start == ORIGIN(FLASH), "NRF_APP_START (board.mk) and the FLASH origin differ")
    ASSERT(ADDR(.text) == ORIGIN(FLASH) && __vectors_start == ORIGIN(FLASH), "the vector table must be the first word of the application")
    ASSERT(__vectors_start % 256 == 0, "the vector table must be 256-byte aligned")
    ASSERT(__text_end <= __romfs_window, "kernel code runs into the /bin window (__romfs_window)")
    ASSERT(__flash_end <= __uf2_limit, "image ends at or above 0xAD000: Adafruit bootloader 0.2.6 would silently not write the rest (see the comment at the top)")
    ASSERT(__flash_end <= ORIGIN(FLASH) + LENGTH(FLASH), "image runs into the bootloader's application-data area (0xEA000)")
    ASSERT(__heap_end > __heap_start + 0x4000, "less than 16 KB of RAM left for the kernel heap")
    ASSERT(__user_start % __user_size == 0, "the shared user arena is not aligned to its size")
    ASSERT(__prog_start % 0x4000 == 0, "the program arena should start on a 16 KB boundary")
}
