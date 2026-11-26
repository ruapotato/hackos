/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- context switch, system-call entry and exit (ARMv7-M, Cortex-M7).
 *
 * This is the kernel's exception entry/exit code; everything it calls is
 * Adder.  Offsets into `class Thread` (kernel/sched/core.ad):               */
        .equ    T_SP,          0        /* saved PSP                       */
        .equ    T_EXC,         4        /* EXC_RETURN to resume with       */
        .equ    T_CTRL,        8        /* CONTROL.nPRIV to resume with    */
        .equ    T_USP,        12        /* caller's frame during a syscall */
        .equ    T_SVC_EXC,    16        /* EXC_RETURN of the entering SVC  */
        .equ    T_KSTACK_TOP, 20
        .equ    T_SVC_CTRL,   24        /* caller's CONTROL.nPRIV          */
        .equ    KERNEL_BASEPRI, 0x40
        .equ    FPCCR,        0xE000EF34

        .syntax unified
        .cpu cortex-m7
        .fpu fpv5-d16
        .thumb

        .macro  func name
        .section .text.\name, "ax", %progbits
        .global \name
        .thumb_func
        .type   \name, %function
\name:
        .endm

/* ------------------------------------------------------------------ */
/* PendSV: the context switch                                          */
/* ------------------------------------------------------------------ */
/* On entry the core has pushed r0-r3, r12, lr, pc, xPSR on the thread's
 * stack (PSP), and, if the thread has used the FPU (EXC_RETURN bit 4 clear),
 * reserved room for s0-s15 and FPSCR without writing it yet (lazy stacking:
 * FPCCR.LSPACT is set and FPCAR points at the room).  The `vstmdb` below is
 * the first FP instruction in the handler, so it makes the core write that
 * lazy state before d8-d15 follow it.  A thread that has not used the FPU
 * costs nothing here.
 *
 * Saved below the exception frame: [d8-d15 if FP], r4-r11.               */
        func    pendsv_handler
        mrs     r0, psp
        tst     lr, #0x10
        it      eq
        vstmdbeq r0!, {d8-d15}
        stmdb   r0!, {r4-r11}
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        str     r0, [r2, #T_SP]
        str     lr, [r2, #T_EXC]
        mrs     r1, control
        and     r1, r1, #1
        str     r1, [r2, #T_CTRL]
        movs    r0, #KERNEL_BASEPRI     /* the ready queues are shared     */
        msr     basepri, r0             /* with interrupt handlers         */
        bl      sched_pick              /* Adder: updates sched_current    */
        movs    r0, #0
        msr     basepri, r0
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        ldr     r0, [r2, #T_SP]
        ldr     lr, [r2, #T_EXC]
        ldr     r1, [r2, #T_CTRL]
        ldmia   r0!, {r4-r11}
        tst     lr, #0x10
        it      eq
        vldmiaeq r0!, {d8-d15}
        msr     psp, r0
        mrs     r2, control
        bic     r2, r2, #1
        orr     r2, r2, r1
        msr     control, r2             /* privilege of the incoming thread */
        isb
        bx      lr
        .size   pendsv_handler, . - pendsv_handler

/* ------------------------------------------------------------------ */
/* sched_launch(): enter the first thread.  Called once from the boot   */
/* context (thread mode, MSP, privileged) with interrupts disabled.     */
/* ------------------------------------------------------------------ */
        func    sched_launch
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        ldr     r0, [r2, #T_SP]
        adds    r0, #32                 /* skip the r4-r11 slots           */
        msr     psp, r0
        ldr     r6, [r2, #T_CTRL]
        ldr     r1, =__stack_top        /* the boot stack is abandoned:    */
        msr     msp, r1                 /* handlers start from its top     */
        movs    r1, #2
        msr     control, r1             /* thread mode now runs on PSP     */
        isb
        pop     {r0-r3, r12, lr}        /* unstack the initial frame by hand */
        pop     {r4, r5}                /* pc, xPSR                        */
        orr     r6, r6, #2
        cpsie   i
        msr     control, r6             /* drop privilege for a user thread */
        isb
        orr     r4, r4, #1
        bx      r4
        .ltorg
        .size   sched_launch, . - sched_launch

/* ------------------------------------------------------------------ */
/* SVCall                                                              */
/* ------------------------------------------------------------------ */
/* svc #0  system call.   The caller used the Adder calling convention for
 *         hackos_syscall(nr, a0, a1, ...): nr in r0:r1, a0 in r2:r3, a1...
 *         in 8-byte slots on its stack.  All of that is in, or just above,
 *         the exception frame the core pushed on the caller's stack.
 * svc #1  return from a system call (issued by syscall_trampoline only).
 *
 * A system call does not run in the SVC handler.  The handler moves the
 * thread onto its kernel stack, makes it privileged and returns into
 * syscall_trampoline in THREAD mode, so the system call is ordinary
 * preemptible kernel code that may block.  `svc #1` undoes that and returns
 * through the caller's original exception frame, with the result written to
 * its r0:r1 slots by syscall_dispatch.
 *
 * Floating point across a system call: if the caller has an FP context
 * (EXC_RETURN bit 4 clear), its s0-s15/FPSCR are written to its frame here
 * (the vstmdb triggers the lazy save) and d8-d15 are parked on the kernel
 * stack, because the kernel part runs with a fresh FP context and a context
 * switch saves d8-d15 only for a thread that has one.                    */
        func    svc_handler
        tst     lr, #4
        ite     eq
        mrseq   r0, msp
        mrsne   r0, psp                 /* r0 = caller's exception frame   */
        tst     lr, #8                  /* must come from thread mode      */
        beq     svc_bad
        tst     lr, #4                  /* ... on the process stack        */
        beq     svc_bad
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]                /* r2 = current thread             */
        cmp     r2, #0
        beq     svc_bad
        ldr     r1, [r0, #24]           /* stacked pc                      */
        ldrb    r1, [r1, #-2]           /* immediate of the svc instruction */
        cmp     r1, #1
        beq     svc_sysret
        cmp     r1, #0
        bne     svc_bad

        /* ---- system call entry ---- */
        ldr     r1, [r2, #T_USP]
        cmp     r1, #0
        bne     svc_bad                 /* already inside a system call    */
        str     r0, [r2, #T_USP]
        str     lr, [r2, #T_SVC_EXC]
        mrs     r1, control
        and     r1, r1, #1
        str     r1, [r2, #T_SVC_CTRL]
        cmp     r1, #0                  /* kernel stack: its top for a user */
        ite     ne                      /* thread; below the frame for a   */
        ldrne   r3, [r2, #T_KSTACK_TOP] /* privileged caller               */
        moveq   r3, r0
        tst     lr, #0x10
        it      eq
        vstmdbeq r3!, {d8-d15}
        sub     r3, r3, #32             /* frame that enters the trampoline */
        movs    r1, #0
        str     r0, [r3, #0]            /* r0:r1 = caller's frame          */
        str     r1, [r3, #4]
        str     r1, [r3, #8]
        str     r1, [r3, #12]
        str     r1, [r3, #16]
        str     r1, [r3, #20]           /* lr                              */
        ldr     r1, =syscall_trampoline
        bic     r1, r1, #1
        str     r1, [r3, #24]           /* pc                              */
        mov     r1, #0x01000000
        str     r1, [r3, #28]           /* xPSR: Thumb                     */
        msr     psp, r3
        mrs     r1, control
        bic     r1, r1, #1
        msr     control, r1             /* privileged thread mode          */
        isb
        mvn     lr, #2                  /* 0xFFFFFFFD: thread, PSP, no FP  */
        bx      lr

        /* ---- system call exit ---- */
svc_sysret:
        mrs     r1, control
        tst     r1, #1
        bne     svc_bad                 /* only the kernel may do this     */
        ldr     r0, [r2, #T_USP]
        cmp     r0, #0
        beq     svc_bad
        ldr     r12, [r2, #T_SVC_EXC]
        ldr     r1, [r2, #T_SVC_CTRL]
        movs    r3, #0
        str     r3, [r2, #T_USP]
        /* The svc #1 itself may have armed a lazy FP save pointing at the
         * kernel-stack frame that is being thrown away: cancel it.        */
        ldr     r3, =FPCCR
        ldr     lr, [r3]
        bic     lr, lr, #1              /* LSPACT                          */
        str     lr, [r3]
        tst     r12, #0x10
        bne     1f
        cmp     r1, #0
        ite     ne
        ldrne   r3, [r2, #T_KSTACK_TOP]
        moveq   r3, r0
        sub     r3, r3, #64
        vldmia  r3, {d8-d15}            /* the caller's callee-saved FP    */
1:      msr     psp, r0
        mrs     r3, control
        bic     r3, r3, #1
        orr     r3, r3, r1
        msr     control, r3             /* back to the caller's privilege  */
        isb
        mov     lr, r12
        bx      lr                      /* unstacks the caller's frame     */

svc_bad:
        movs    r0, #11
        b       hackos_fault_entry
        .ltorg
        .size   svc_handler, . - svc_handler

/* Thread mode, privileged, on the kernel stack.  r0:r1 = caller's frame. */
        func    syscall_trampoline
        bl      syscall_dispatch        /* Adder; writes the result into   */
        svc     #1                      /* the caller's frame              */
1:      b       1b
        .size   syscall_trampoline, . - syscall_trampoline

/* ------------------------------------------------------------------ */
/* User side                                                           */
/* ------------------------------------------------------------------ */
/* hackos_syscall(nr, a0, a1, a2, a3, a4, a5) -> int64
 * The arguments are already where the handler looks for them.          */
        func    hackos_syscall
        svc     #0
        bx      lr
        .size   hackos_syscall, . - hackos_syscall

/* Return address of a user thread's entry function: exit(result).      */
        func    uthread_exit_stub
        mov     r2, r0                  /* a0 = the function's result      */
        mov     r3, r1
        movs    r0, #1                  /* SYS_EXIT                        */
        movs    r1, #0
        svc     #0
1:      b       1b
        .size   uthread_exit_stub, . - uthread_exit_stub
