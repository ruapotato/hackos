/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- regprobe: what does a brand-new program find in its registers?
 *
 * A program must not start with anything another program (or the kernel)
 * left behind.  This one is its own entry point, so nothing has run before
 * the first instruction below.  It ORs together every register the kernel
 * does not use to pass something in, and exits with
 *     bit 0   a core register was not zero (r4-r8, r10-r12, lr; r9 too
 *             unless the program is RWPI, where r9 is its static base)
 *     bit 1   a floating-point register was not zero (s0-s31)
 *     bit 2   FPSCR was not zero
 * r0-r3 carry argc and argv.  Reading s0 is this program's first use of the
 * FPU, which is exactly the case in question.                             */
        .syntax unified
#ifdef HACKOS_CPU_M4
        .cpu cortex-m4
        .fpu fpv4-sp-d16
#else
        .cpu cortex-m7
        .fpu fpv5-d16
#endif
        .thumb
        .section .text.hackos_crt_start, "ax", %progbits
        .global hackos_crt_start
        .thumb_func
        .type   hackos_crt_start, %function
hackos_crt_start:
        orrs    r4, r5
        orrs    r4, r6
        orrs    r4, r7
        orr     r4, r4, r8
        orr     r4, r4, r10
        orr     r4, r4, r11
        orr     r4, r4, r12
        orr     r4, r4, lr
#ifndef HACKOS_RWPI
        orr     r4, r4, r9
#endif
        movs    r2, #0
        cbz     r4, 1f
        movs    r2, #1
1:      movs    r5, #0
        .irp    n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
        vmov    r6, s\n
        orrs    r5, r6
        .endr
        cbz     r5, 2f
        orr     r2, r2, #2
2:      vmrs    r6, fpscr
        cbz     r6, 3f
        orr     r2, r2, #4
3:      movs    r0, #1                  /* exit(r2:r3) */
        movs    r1, #0
        movs    r3, #0
        svc     #0
4:      b       4b
        .size   hackos_crt_start, . - hackos_crt_start
