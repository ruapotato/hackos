/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Entry for the uSDHC test image on QEMU `-M mcimx6ul-evk` (Cortex-A7).
 * QEMU starts an ELF in ARM state; the code under test is Thumb-2 built for
 * the Cortex-M7 (it is a subset of what the A7 executes in Thumb state), so
 * this stub sets a stack and enters it with BLX.  No exceptions are taken:
 * no vector table, MMU and caches off.                                    */
        .syntax unified
        .arm
        .section .text.entry, "ax", %progbits
        .global _entry
_entry:
        ldr     sp, =__stack_top
        ldr     r12, =a7_main
        blx     r12
1:      b       1b
        .ltorg
