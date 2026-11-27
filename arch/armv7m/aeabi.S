/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- EABI run-time helper shims (ARMv7-M, hard float).
 *
 * LLVM calls __aeabi_uldivmod, __aeabi_memcpy, __aeabi_l2d and friends with
 * the C convention; their implementations are Adder functions (kernel/rt.ad)
 * with the Adder convention (64-bit argument slots).  These shims sit in
 * between.  The kernel links this file, and so does every user program
 * (user/rt/): the code is position-independent (PC-relative calls only) and
 * touches no data.
 */
        .syntax unified
#ifdef HACKOS_CPU_M4                    /* Cortex-M4F: single-precision FPU */
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb

/* ------------------------------------------------------------------ */
/* 4. EABI run-time helper shims -> Adder implementations (kernel/rt.ad) */
/* ------------------------------------------------------------------ */
        .macro  func name
        .section .text.\name, "ax", %progbits
        .global \name
        .thumb_func
        .type   \name, %function
\name:
        .endm

/* {q=r0:r1, r=r2:r3} __aeabi_uldivmod(n=r0:r1, d=r2:r3)
 * -> rt_udivmod64(n, d, rem_out: Ptr[uint64]) -> uint64               */
        func    __aeabi_uldivmod
        push    {r4, lr}
        sub     sp, #16                 /* [sp+0] arg2, [sp+8] remainder   */
        add     r12, sp, #8
        str     r12, [sp]
        movs    r4, #0
        str     r4, [sp, #4]
        bl      rt_udivmod64
        ldr     r2, [sp, #8]
        ldr     r3, [sp, #12]
        add     sp, #16
        pop     {r4, pc}

/* signed: -> rt_sdivmod64(n, d, rem_out: Ptr[int64]) -> int64          */
        func    __aeabi_ldivmod
        push    {r4, lr}
        sub     sp, #16
        add     r12, sp, #8
        str     r12, [sp]
        movs    r4, #0
        str     r4, [sp, #4]
        bl      rt_sdivmod64
        ldr     r2, [sp, #8]
        ldr     r3, [sp, #12]
        add     sp, #16
        pop     {r4, pc}

/* The C names `memcpy`, `memmove` and `memset` are deliberately NOT defined:
 * on an EABI target LLVM calls the __aeabi_* forms, and Adder code (Hamnix
 * sources in particular) defines and calls functions named memcpy/memset with
 * the Adder convention (64-bit argument slots).  One symbol cannot serve both
 * conventions; a C-convention `memcpy` here would silently bind to those
 * calls and copy from the wrong address.
 *
 * void __aeabi_memcpy(dst=r0, src=r1, n=r2) -> rt_memcpy(dst, src, n)  */
        func    __aeabi_memcpy
        .global __aeabi_memcpy4
        .global __aeabi_memcpy8
        .thumb_set __aeabi_memcpy4, __aeabi_memcpy
        .thumb_set __aeabi_memcpy8, __aeabi_memcpy
        push    {r4, lr}
        sub     sp, #8
        str     r2, [sp]                /* arg2 = n                        */
        movs    r3, #0
        str     r3, [sp, #4]
        mov     r2, r1                  /* arg1 = src (r2:r3)              */
        movs    r1, #0                  /* arg0 = dst (r0:r1)              */
        bl      rt_memcpy
        add     sp, #8
        pop     {r4, pc}

        func    __aeabi_memmove
        .global __aeabi_memmove4
        .global __aeabi_memmove8
        .thumb_set __aeabi_memmove4, __aeabi_memmove
        .thumb_set __aeabi_memmove8, __aeabi_memmove
        push    {r4, lr}
        sub     sp, #8
        str     r2, [sp]
        movs    r3, #0
        str     r3, [sp, #4]
        mov     r2, r1
        movs    r1, #0
        bl      rt_memmove
        add     sp, #8
        pop     {r4, pc}

/* void __aeabi_memset(dst=r0, n=r1, c=r2)   (note the argument order)  */
        func    __aeabi_memset
        .global __aeabi_memset4
        .global __aeabi_memset8
        .thumb_set __aeabi_memset4, __aeabi_memset
        .thumb_set __aeabi_memset8, __aeabi_memset
        push    {r4, lr}
        sub     sp, #8
        str     r1, [sp]                /* arg2 = n                        */
        movs    r3, #0
        str     r3, [sp, #4]
        movs    r1, #0                  /* arg0 = dst; arg1 = c already r2 */
        bl      rt_memset
        add     sp, #8
        pop     {r4, pc}

/* void __aeabi_memclr(dst=r0, n=r1)                                    */
        func    __aeabi_memclr
        .global __aeabi_memclr4
        .global __aeabi_memclr8
        .thumb_set __aeabi_memclr4, __aeabi_memclr
        .thumb_set __aeabi_memclr8, __aeabi_memclr
        push    {r4, lr}
        sub     sp, #8
        str     r1, [sp]
        movs    r3, #0
        str     r3, [sp, #4]
        movs    r1, #0
        movs    r2, #0
        bl      rt_memset
        add     sp, #8
        pop     {r4, pc}

/* 64-bit integer <-> double.  The __aeabi_* helpers use the BASE procedure
 * call standard even on a hard-float target (double in r0:r1, not d0), so
 * the shims move the value between the core pair and d0.               */
        func    __aeabi_l2d             /* double(int64 r0:r1)             */
        push    {r4, lr}
        bl      rt_i64_to_f64
        vmov    r0, r1, d0
        pop     {r4, pc}

        func    __aeabi_ul2d            /* double(uint64 r0:r1)            */
        push    {r4, lr}
        bl      rt_u64_to_f64
        vmov    r0, r1, d0
        pop     {r4, pc}

        func    __aeabi_d2lz            /* int64(double r0:r1), truncating */
        push    {r4, lr}
        vmov    d0, r0, r1
        bl      rt_f64_to_i64
        pop     {r4, pc}

        func    __aeabi_d2ulz           /* uint64(double r0:r1)            */
        push    {r4, lr}
        vmov    d0, r0, r1
        bl      rt_f64_to_u64
        pop     {r4, pc}
