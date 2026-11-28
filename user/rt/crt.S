/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- the one piece of a user program that has to be assembly: the
 * system-call instruction.
 *
 * hackos_syscall(nr, a0, a1, a2, a3, a4, a5) -> int64, Adder convention:
 * nr in r0:r1, a0 in r2:r3, a1.. in 8-byte slots on the stack.  The kernel
 * reads them from the exception frame the `svc` pushes and from just above
 * it, and writes the result to the frame's r0:r1 (kernel/syscall.ad).
 *
 * The entry point of a program is hackos_crt_start in user/rt/rt.ad.     */
        .syntax unified
#ifdef HACKOS_CPU_M4                    /* Cortex-M4F: single-precision FPU */
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb

        .section .text.hackos_syscall, "ax", %progbits
        .global hackos_syscall
        .thumb_func
        .type   hackos_syscall, %function
hackos_syscall:
        svc     #0
        bx      lr
        .size   hackos_syscall, . - hackos_syscall

/* hackos_heap_lo() / hackos_heap_hi() -> uint64: the heap's bounds
 * (user/rt/prog.ld, prog_rwpi.ld).  A PIE reaches them PC-relative; an RWPI
 * program's data is wherever the kernel put it, at r9 (the static base) plus
 * the link-time offset from the start of the data segment.            */
        .macro  heap_bound name, sym
        .section .text.\name, "ax", %progbits
        .global \name
        .thumb_func
        .type   \name, %function
\name:
        ldr     r0, 1f
#ifdef HACKOS_RWPI
        add     r0, r9
#else
2:      add     r0, pc
#endif
        movs    r1, #0
        bx      lr
        .p2align 2
#ifdef HACKOS_RWPI
1:      .word   \sym(sbrel)
#else
1:      .word   \sym - (2b + 4)
#endif
        .size   \name, . - \name
        .endm

        heap_bound hackos_heap_lo, __heap_start
        heap_bound hackos_heap_hi, __heap_end

/* ---- test helpers (linked only into a program that calls them) ---------- */
/* hackos_test_dirty_fp(): leave a recognisable value in every FP register
 * and set the FPSCR flags, as a program that computes would.  For the tests
 * of "a new program starts with clean registers" (user/progs/regprobe.S). */
        .section .text.hackos_test_dirty_fp, "ax", %progbits
        .global hackos_test_dirty_fp
        .thumb_func
        .type   hackos_test_dirty_fp, %function
hackos_test_dirty_fp:
        movw    r0, #0xBEEF
        movt    r0, #0x5EC0
        .irp    n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
        vmov    s\n, r0
        .endr
        mov     r0, #0xF0000000         /* N Z C V */
        orr     r0, r0, #0x9F           /* the cumulative exception flags */
        vmsr    fpscr, r0
        bx      lr
        .size   hackos_test_dirty_fp, . - hackos_test_dirty_fp

/* hackos_test_exec_dirty(path, argv): execve_env(path, argv, 0) made with
 * every callee-saved core register and every FP register holding a
 * recognisable value.  Returns only if the exec failed (the callee-saved
 * registers are restored then).  Adder convention: path in r0:r1, argv in
 * r2:r3.                                                                 */
        .section .text.hackos_test_exec_dirty, "ax", %progbits
        .global hackos_test_exec_dirty
        .thumb_func
        .type   hackos_test_exec_dirty, %function
hackos_test_exec_dirty:
        push    {r4-r11, lr}
        sub     sp, sp, #20             /* a1 (argv) and a2 (envp), 8 bytes each; 4 to stay 8-aligned */
        str     r2, [sp, #0]
        movs    r2, #0
        str     r2, [sp, #4]
        str     r2, [sp, #8]
        str     r2, [sp, #12]
        mov     r2, r0                  /* a0 = path */
        movs    r3, #0
        bl      hackos_test_dirty_fp
        movw    r4, #0x1234
        movt    r4, #0x5EC0
        mov     r5, r4
        mov     r6, r4
        mov     r7, r4
        mov     r8, r4
        mov     r10, r4
        mov     r11, r4
#ifndef HACKOS_RWPI
        mov     r12, r9
        mov     r9, r4
#endif
        movs    r0, #10                 /* SYS_EXECVE */
        movs    r1, #0
        svc     #0
#ifndef HACKOS_RWPI
        mov     r9, r12
#endif
        add     sp, sp, #20
        pop     {r4-r11, pc}
        .size   hackos_test_exec_dirty, . - hackos_test_exec_dirty
