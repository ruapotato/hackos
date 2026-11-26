/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- ARMv7-M (Cortex-M7) start-up and ABI glue.
 *
 * This file holds ONLY what cannot be written in Adder:
 *   1. the vector table (a data table at a fixed section),
 *   2. the reset stub (the FPU must be on before any compiled code runs,
 *      because LLVM is free to move 64-bit values through d-registers),
 *   3. the fault entry stub (must read LR/MSP/PSP before any prologue),
 *   4. calling-convention shims between the EABI run-time helper names that
 *      LLVM calls (__aeabi_uldivmod, __aeabi_memcpy, __aeabi_l2d, ...) and
 *      their implementations, which ARE written in Adder (kernel/rt.ad).
 *
 * ADDER <-> ASSEMBLY CALLING CONVENTION on thumbv7em-none-eabihf
 * (see the compiler's docs/cortex_m7.md):
 *   every Adder integer/pointer argument is a 64-bit value.  AAPCS-VFP puts
 *   64-bit integers in an even/odd core register pair:
 *       arg0 -> r0 (low) : r1 (high)
 *       arg1 -> r2 (low) : r3 (high)
 *       arg2.. -> the stack, 8 bytes each, 8-byte aligned, low word first
 *   float64 arguments go in d0..d7 and do not consume core registers.
 *   An integer/pointer result is r0 (low) : r1 (high); float64 is d0.
 *   A pointer passed TO Adder must have its high word zero.
 */
        .syntax unified
        .cpu cortex-m7
        .fpu fpv5-d16
        .thumb

/* ------------------------------------------------------------------ */
/* 1. Vector table                                                    */
/* ------------------------------------------------------------------ */
        .section .vectors, "a", %progbits
        .global hackos_vectors
        .type hackos_vectors, %object
hackos_vectors:
        .word   __stack_top             /*  0 initial MSP                 */
        .word   Reset_Handler           /*  1 reset                       */
        .word   nmi_handler             /*  2 NMI                         */
        .word   HardFault_Handler       /*  3                             */
        .word   MemManage_Handler       /*  4                             */
        .word   BusFault_Handler        /*  5                             */
        .word   UsageFault_Handler      /*  6                             */
        .word   0, 0, 0, 0              /*  7..10 reserved                */
        .word   svc_handler             /* 11 SVCall     (Adder, weak)    */
        .word   debugmon_handler        /* 12                             */
        .word   0                       /* 13 reserved                    */
        .word   pendsv_handler          /* 14 PendSV     (Adder, weak)    */
        .word   systick_handler         /* 15 SysTick    (Adder, weak)    */
        .rept   32                      /* 16.. external interrupts 0..31 */
        .word   irq_default_handler
        .endr
        .size hackos_vectors, . - hackos_vectors

/* Handlers a kernel may define in Adder.  A plain zero-argument Adder
 * function IS a valid exception handler: the core stacks r0-r3,r12,lr,pc,xPSR
 * (and the FP context, lazily), which is exactly the AAPCS caller-saved set,
 * keeps the stack 8-byte aligned (CCR.STKALIGN resets to 1 on Cortex-M7) and
 * returns through the EXC_RETURN value in LR like a normal `bx lr`.
 * Anything not defined falls into the "unexpected exception" report. */
        .macro  weak_handler name, kind
        .section .text.\name, "ax", %progbits
        .weak   \name
        .thumb_func
        .type   \name, %function
\name:
        movs    r0, #\kind
        b       hackos_fault_entry
        .size   \name, . - \name
        .endm

        weak_handler nmi_handler, 2
        weak_handler svc_handler, 11
        weak_handler debugmon_handler, 12
        weak_handler pendsv_handler, 14
        weak_handler systick_handler, 15
        weak_handler irq_default_handler, 16

/* ------------------------------------------------------------------ */
/* 2. Reset stub                                                      */
/* ------------------------------------------------------------------ */
        .section .text.Reset_Handler, "ax", %progbits
        .global Reset_Handler
        .thumb_func
        .type   Reset_Handler, %function
Reset_Handler:
        cpsid   i
        ldr     r0, =__stack_top        /* do not rely on the loader's MSP */
        mov     sp, r0
        /* CPACR (0xE000ED88): full access to CP10+CP11 = enable the FPU.  */
        ldr     r0, =0xE000ED88
        ldr     r1, [r0]
        orr     r1, r1, #(0xF << 20)
        str     r1, [r0]
        dsb
        isb
        /* Everything else (VTOR, .data copy, .bss clear, main) is Adder.  */
        bl      hackos_start
1:      wfi                             /* hackos_start does not return    */
        b       1b
        .size   Reset_Handler, . - Reset_Handler
        .ltorg

/* ------------------------------------------------------------------ */
/* 3. Fault entry                                                     */
/* ------------------------------------------------------------------ */
/* hackos_fault(kind: uint64, frame: uint64, exc_return: uint64)       */
        .macro  fault_handler name, kind
        .section .text.\name, "ax", %progbits
        .global \name
        .thumb_func
        .type   \name, %function
\name:
        movs    r0, #\kind
        b       hackos_fault_entry
        .size   \name, . - \name
        .endm

        fault_handler HardFault_Handler, 3
        fault_handler MemManage_Handler, 4
        fault_handler BusFault_Handler, 5
        fault_handler UsageFault_Handler, 6

        .section .text.hackos_fault_entry, "ax", %progbits
        .thumb_func
        .type   hackos_fault_entry, %function
hackos_fault_entry:
        cpsid   i
        movs    r1, #0                  /* arg0 = kind (r0:r1)             */
        tst     lr, #4                  /* EXC_RETURN bit 2: 0=MSP 1=PSP   */
        ite     eq
        mrseq   r2, msp
        mrsne   r2, psp                 /* arg1 = stacked frame (r2:r3)    */
        movs    r3, #0
        mov     r12, lr
        ldr     r3, =__fault_stack_top  /* own stack: the faulting one may */
        mov     sp, r3                  /* be bad, and must not be reused  */
        movs    r3, #0                  /* (the stacked frame lives on it) */
        sub     sp, #8
        str     r12, [sp]               /* arg2 = EXC_RETURN (stack, 64b)  */
        str     r3, [sp, #4]
        bl      hackos_fault
1:      b       1b
        .size   hackos_fault_entry, . - hackos_fault_entry
        .ltorg

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
