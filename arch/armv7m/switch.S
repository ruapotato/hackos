/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- context switch, system-call entry and exit (ARMv7-M, Cortex-M7).
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
        .equ    T_EXEC_NEW,   28        /* 1: an exec has just loaded a program */
        .equ    T_SVC_REGS,   32        /* caller's r4-r11 at system-call entry */
        .equ    T_KLO,        64        /* lowest address a context may be saved at on the kernel stack */
        .equ    T_ULO,        68        /* ... on the thread's own (unprivileged) stack */
        .equ    T_UHI,        72        /* end of the memory its unprivileged stack pointer may be in */
        .equ    T_STATE,      80        /* scheduler state                 */
        .equ    T_ZOMBIE,      4
        .equ    KERNEL_BASEPRI, 0x40
        .equ    FPCCR,        0xE000EF34

        .syntax unified
#ifdef HMICRO_CPU_M4                    /* Cortex-M4F: single-precision FPU */
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb

/* Zero s0-s31 and FPSCR.  \r is a core register that may be clobbered. */
        .macro  fpzero r
        movs    \r, #0
        .irp    n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        vmov    d\n, \r, \r
        .endr
        vmsr    fpscr, \r
        .endm

/* Floating-point registers must not carry values from one thread to
 * another.  A thread WITH an FP context has its own values saved and
 * restored.  A thread WITHOUT one (it has not used the FPU yet, or it is in
 * the kernel part of a system call) would see whatever the last user left:
 * so when such a thread is switched in and the registers may hold somebody's
 * values (fp_dirty), they are zeroed.  fp_dirty is set wherever a thread
 * with an FP context leaves the processor: at its context switch and at its
 * system-call entry.  A system that never touches the FPU pays four
 * instructions per switch for this.                                      */
        .section .bss.fp_dirty, "aw", %nobits
        .global fp_dirty
fp_dirty:
        .byte   0
        .p2align 2

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
        /* The context goes below the thread's stack pointer, written with
         * the handler's privilege.  So first: is there room for it where
         * this thread's stack may be?  A kernel stack that is nearly full
         * would take the save into its guard (a fault in handler mode,
         * which is fatal); an unprivileged thread whose stack pointer sits
         * at the very bottom of its memory, or anywhere it likes, would
         * have the kernel write below or outside what it owns.  A thread
         * without the room is ended as a stack overflow instead
         * (sched_bad_stack) and nothing is saved.                         */
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        mrs     r1, control
        tst     r1, #1
        ite     ne
        ldrne   r3, [r2, #T_ULO]        /* running unprivileged: its own stack */
        ldreq   r3, [r2, #T_KLO]        /* kernel thread, or inside a system call */
        ite     ne
        ldrne   r12, [r2, #T_UHI]
        ldreq   r12, [r2, #T_KSTACK_TOP]
        sub     r1, r0, #32
        tst     lr, #0x10
        it      eq
        subeq   r1, r1, #64
        cmp     r1, r3
        blo     9f
        cmp     r0, r12
        bhi     9f
        tst     lr, #0x10
        bne     1f
        vstmdb  r0!, {d8-d15}
        movw    r3, #:lower16:fp_dirty
        movt    r3, #:upper16:fp_dirty
        movs    r1, #1
        strb    r1, [r3]
1:      stmdb   r0!, {r4-r11}
        str     r0, [r2, #T_SP]         /* r2 is still the current thread  */
        str     lr, [r2, #T_EXC]
        mrs     r1, control
        and     r1, r1, #1
        str     r1, [r2, #T_CTRL]
8:      movs    r0, #KERNEL_BASEPRI     /* the ready queues are shared     */
        msr     basepri, r0             /* with interrupt handlers         */
        bl      sched_pick              /* Adder: updates sched_current    */
        movs    r0, #0
        msr     basepri, r0
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        ldr     r0, [r2, #T_SP]
        ldr     lr, [r2, #T_EXC]
        ldmia   r0!, {r4-r11}
        tst     lr, #0x10
        bne     2f
        vldmia  r0!, {d8-d15}
        b       3f
2:      movw    r3, #:lower16:fp_dirty  /* no FP context: it must not see */
        movt    r3, #:upper16:fp_dirty  /* another thread's values        */
        ldrb    r1, [r3]
        cbz     r1, 3f
        movs    r1, #0
        strb    r1, [r3]
        fpzero  r1
3:      ldr     r1, [r2, #T_CTRL]
        msr     psp, r0
        mrs     r2, control
        bic     r2, r2, #1
        orr     r2, r2, r1
        msr     control, r2             /* privilege of the incoming thread */
        isb
        bx      lr
9:      push    {r4, lr}                /* no room for the context: end the thread */
        bl      sched_bad_stack         /* Adder: r0:r1 = its stack pointer */
        pop     {r4, lr}
        b       8b
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
 *         hmicro_syscall(nr, a0, a1, ...): nr in r0:r1, a0 in r2:r3, a1...
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
        /* An `svc` executed with a stack pointer the thread may not use:
         * pushing the exception frame faulted, the fault handler has ended
         * the thread, and the SVCall that was pending all along arrives
         * here afterwards.  There is no frame to read and nobody to serve.
         * Return: the context switch the fault handler asked for is still
         * pending and runs before anything is unstacked.                  */
        ldr     r1, [r2, #T_STATE]
        cmp     r1, #T_ZOMBIE
        it      eq
        bxeq    lr
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
        add     r3, r2, #T_SVC_REGS     /* the caller's callee-saved core   */
        stmia   r3, {r4-r11}            /* registers, for rfork (a child    */
                                        /* starts with a copy of them)      */
        cmp     r1, #0                  /* kernel stack: its top for a user */
        ite     ne                      /* thread; below the frame for a   */
        ldrne   r3, [r2, #T_KSTACK_TOP] /* privileged caller               */
        moveq   r3, r0
        tst     lr, #0x10
        bne     4f
        vstmdb  r3!, {d8-d15}
        movw    r1, #:lower16:fp_dirty  /* the caller's values stay in the */
        movt    r1, #:upper16:fp_dirty  /* registers while the kernel part */
        mov     r12, #1                 /* runs without an FP context      */
        strb    r12, [r1]
4:      sub     r3, r3, #32             /* frame that enters the trampoline */
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
        movs    r3, #0
        str     r3, [r2, #T_USP]
        /* The svc #1 itself may have armed a lazy FP save pointing at the
         * kernel-stack frame that is being thrown away: cancel it.        */
        ldr     r3, =FPCCR
        ldr     r1, [r3]
        bic     r1, r1, #1              /* LSPACT                          */
        str     r1, [r3]
        ldr     r1, [r2, #T_SVC_CTRL]
        tst     r12, #0x10
        bne     2f
        cmp     r1, #0
        ite     ne
        ldrne   r3, [r2, #T_KSTACK_TOP]
        moveq   r3, r0
        sub     r3, r3, #64
        vldmia  r3, {d8-d15}            /* the caller's callee-saved FP    */
        b       1f
        /* The caller has no FP context.  If the kernel part of the call
         * used the FPU (lr, the EXC_RETURN of this svc #1, says so), its
         * values are in the registers: the caller must not find them.    */
2:      tst     lr, #0x10
        bne     1f
        fpzero  r3
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
        b       hmicro_fault_entry
        .ltorg
        .size   svc_handler, . - svc_handler

/* Thread mode, privileged, on the kernel stack.  r0:r1 = caller's frame. */
        func    syscall_trampoline
        bl      syscall_dispatch        /* Adder; writes the result into   */
                                        /* the caller's frame              */
        /* An exec that loaded a new program (kernel/proc.ad) sets T_EXEC_NEW
         * and leaves the new program's r4-r11 in T_SVC_REGS: zeros, and in
         * r9 the static base of an RWPI program.  The return then carries
         * nothing of the old image: not its callee-saved core registers
         * (which this code would otherwise still hold, as the kernel
         * preserves them) and not its floating-point registers.  Using the
         * FPU here gives the svc #1 an FP frame on the kernel stack, which
         * svc_sysret throws away.                                         */
        movw    r3, #:lower16:sched_current
        movt    r3, #:upper16:sched_current
        ldr     r2, [r3]
        ldr     r0, [r2, #T_EXEC_NEW]
        cbz     r0, 2f
        movs    r0, #0
        str     r0, [r2, #T_EXEC_NEW]
        add     r0, r2, #T_SVC_REGS
        ldmia   r0, {r4-r11}
        fpzero  r0
        movs    r1, #0
        movs    r2, #0
        movs    r3, #0
        mov     r12, r0
2:      svc     #1
1:      b       1b
        .size   syscall_trampoline, . - syscall_trampoline

/* ------------------------------------------------------------------ */
/* User side                                                           */
/* ------------------------------------------------------------------ */
/* hmicro_syscall(nr, a0, a1, a2, a3, a4, a5) -> int64
 * The arguments are already where the handler looks for them.          */
        func    hmicro_syscall
        svc     #0
        bx      lr
        .size   hmicro_syscall, . - hmicro_syscall

/* Return address of a user thread's entry function: exit(result).      */
        func    uthread_exit_stub
        mov     r2, r0                  /* a0 = the function's result      */
        mov     r3, r1
        movs    r0, #1                  /* SYS_EXIT                        */
        movs    r1, #0
        svc     #0
1:      b       1b
        .size   uthread_exit_stub, . - uthread_exit_stub
