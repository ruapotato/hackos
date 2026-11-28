/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro test helper: hold a known pattern in every FPU register while the
 * thread is being preempted, and count how often a register did not hold.
 *
 * fp_hold(seed: uint64, loops: uint64) -> uint64   (Adder convention)
 *   d<i> = { low: seed + i, high: ~(seed + i) } for i = 0..15, then `loops`
 *   passes over all sixteen registers comparing both words.  Returns the
 *   number of mismatching words (0 = the context switch preserved d0-d15).
 * d0-d7 are caller-saved: the core stacks them lazily on exception entry.
 * d8-d15 are callee-saved: the PendSV handler must save them.  Touches no
 * memory except its own stack, so it also runs unprivileged.               */
        .syntax unified
#ifdef HMICRO_CPU_M4                    /* d0-d15 exist as register pairs */
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb
        .section .text.fp_hold, "ax", %progbits
        .global fp_hold
        .thumb_func
        .type   fp_hold, %function
fp_hold:
        push    {r4-r7, lr}
        vpush   {d8-d15}
        mov     r4, r0                  /* seed                            */
        mov     r5, r2                  /* loops                           */
        movs    r6, #0                  /* mismatches                      */
        .irp    i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        add     r1, r4, #\i
        mvn     r3, r1
        vmov    d\i, r1, r3
        .endr
1:
        .irp    i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        vmov    r1, r3, d\i
        add     r7, r4, #\i
        cmp     r1, r7
        it      ne
        addne   r6, r6, #1
        mvn     r7, r7
        cmp     r3, r7
        it      ne
        addne   r6, r6, #1
        .endr
        subs    r5, r5, #1
        bne     1b
        vpop    {d8-d15}
        mov     r0, r6
        movs    r1, #0
        pop     {r4-r7, pc}
        .size   fp_hold, . - fp_hold
