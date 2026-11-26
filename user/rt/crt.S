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
        .cpu cortex-m7
        .fpu fpv5-d16
        .thumb

        .section .text.hackos_syscall, "ax", %progbits
        .global hackos_syscall
        .thumb_func
        .type   hackos_syscall, %function
hackos_syscall:
        svc     #0
        bx      lr
        .size   hackos_syscall, . - hackos_syscall
