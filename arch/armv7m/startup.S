/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- ARMv7-M (Cortex-M7) start-up and ABI glue.
 *
 * This file holds ONLY what cannot be written in Adder:
 *   1. the vector table (a data table at a fixed section; per board, included),
 *   2. the reset stub (the FPU must be on before any compiled code runs,
 *      because LLVM is free to move 64-bit values through d-registers),
 *   3. the fault entry stub (must read LR/MSP/PSP before any prologue),
 * and, in aeabi.S (shared with user programs),
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
/* 1. Vector tables                                                   */
/* ------------------------------------------------------------------ */
/* Board specific: boards/<board>/vectors.S, found through -Iboards/<board>.
 * It defines hackos_vectors (the table VTOR is pointed at) and whatever the
 * board's boot path needs before it (mps2-an500: the reset-only table at
 * address 0; teensy41: the FlexSPI boot header).  A board that must run code
 * before the stack pointer is usable defines BOARD_RESET_EARLY and a leaf
 * routine board_reset_early that uses no stack.                          */
#include "vectors.S"

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
        weak_handler uart0_rx_handler, 16

/* ------------------------------------------------------------------ */
/* 2. Reset stub                                                      */
/* ------------------------------------------------------------------ */
        .section .text.Reset_Handler, "ax", %progbits
        .global Reset_Handler
        .thumb_func
        .type   Reset_Handler, %function
Reset_Handler:
        cpsid   i
#ifdef BOARD_RESET_EARLY
        bl      board_reset_early       /* e.g. memory banks; no stack yet */
#endif
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

/* A kernel may define hackos_thread_fault(kind, frame, exc_return) -> uint64
 * in Adder.  It is offered every fault that was taken from THREAD mode on the
 * PROCESS stack: the handler stack is intact in that case, so the kernel can
 * end the offending thread and carry on.  Returning 0 means "handled, return
 * from the exception" (the kernel has made another thread runnable and pended
 * PendSV); anything else falls through to the fatal report.  Without a kernel
 * the weak default below declines everything.                              */
        .section .text.hackos_thread_fault, "ax", %progbits
        .weak   hackos_thread_fault
        .thumb_func
        .type   hackos_thread_fault, %function
hackos_thread_fault:
        movs    r0, #1
        movs    r1, #0
        bx      lr
        .size   hackos_thread_fault, . - hackos_thread_fault

        .section .text.hackos_fault_entry, "ax", %progbits
        .global hackos_fault_entry
        .thumb_func
        .type   hackos_fault_entry, %function
hackos_fault_entry:
        and     r1, lr, #0xC            /* EXC_RETURN: thread mode + PSP?  */
        cmp     r1, #0xC
        bne     2f
        push    {r0, lr}                /* kind, EXC_RETURN                */
        mov     r12, lr
        movs    r1, #0                  /* arg0 = kind (r0:r1)             */
        mrs     r2, psp                 /* arg1 = stacked frame (r2:r3)    */
        movs    r3, #0
        sub     sp, #8
        str     r12, [sp]               /* arg2 = EXC_RETURN (stack, 64b)  */
        str     r3, [sp, #4]
        bl      hackos_thread_fault
        add     sp, #8
        cmp     r0, #0
        pop     {r0, lr}
        it      eq
        bxeq    lr                      /* handled: PendSV takes over      */
2:      cpsid   i
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

/* 4. The EABI run-time helper shims are in aeabi.S: programs need them too. */
