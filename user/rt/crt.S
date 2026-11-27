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
