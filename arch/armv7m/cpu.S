/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- Cortex-M7 special-register access, callable from Adder.
 *
 * Adder's inline assembly has no operands, so a value can only leave an
 * `asm_volatile` body through a global.  That is not re-entrant: an interrupt
 * between the store to the global and the load of it corrupts the result.
 * Everything that reads or writes a core register therefore lives here as a
 * leaf routine with the Adder calling convention (docs/cortex_m7.md in the
 * compiler tree): a 32-bit argument arrives zero-extended in r0:r1, a result
 * is returned in r0:r1 (r1 = 0).  These routines touch no memory and are safe
 * from any context, including nested interrupts.
 */
        .syntax unified
#ifdef HMICRO_CPU_M4                    /* Cortex-M4F: single-precision FPU */
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb

/* Interrupts whose priority value is >= KERNEL_BASEPRI are "kernel aware":
 * they may call kernel services and are held off by a critical section.
 * Priorities 0x00..0x3F stay enabled inside critical sections and must not
 * touch kernel data.  Keep in step with kernel/cpu.ad.                     */
        .equ    KERNEL_BASEPRI, 0x40

        .macro  leaf name
        .section .text.\name, "ax", %progbits
        .global \name
        .thumb_func
        .type   \name, %function
\name:
        .endm

/* cpu_irq_save() -> uint32: enter a critical section, return the previous
 * BASEPRI.  BASEPRI_MAX only ever raises the mask, so nesting is safe.     */
        leaf    cpu_irq_save
        mrs     r0, basepri
        movs    r1, #KERNEL_BASEPRI
        msr     basepri_max, r1
        movs    r1, #0
        bx      lr

/* cpu_irq_restore(prev: uint32)                                            */
        leaf    cpu_irq_restore
        msr     basepri, r0
        bx      lr

        leaf    cpu_basepri
        mrs     r0, basepri
        movs    r1, #0
        bx      lr

        leaf    cpu_set_basepri
        msr     basepri, r0
        bx      lr

        leaf    cpu_primask
        mrs     r0, primask
        movs    r1, #0
        bx      lr

/* 0 in thread mode, else the active exception number.                      */
        leaf    cpu_ipsr
        mrs     r0, ipsr
        movs    r1, #0
        bx      lr

        leaf    cpu_control
        mrs     r0, control
        movs    r1, #0
        bx      lr

        leaf    cpu_psp
        mrs     r0, psp
        movs    r1, #0
        bx      lr

        leaf    cpu_set_psp
        msr     psp, r0
        bx      lr

        leaf    cpu_msp
        mrs     r0, msp
        movs    r1, #0
        bx      lr

/* Current stack pointer of the caller.                                     */
        leaf    cpu_sp
        mov     r0, sp
        movs    r1, #0
        bx      lr

        leaf    cpu_wfi
        wfi
        bx      lr

        leaf    cpu_isb
        dsb
        isb
        bx      lr
