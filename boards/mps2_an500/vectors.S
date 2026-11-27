/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- vector tables for QEMU `mps2-an500`; included by
 * arch/armv7m/startup.S (moved there from unchanged).                    */
/* Address 0 holds only what reset needs: the core reads the initial MSP and
 * the reset vector from there before any code runs.  The rest of the first
 * 4 KB of the image is empty and becomes an MPU no-access region (the null
 * pointer guard, kernel/mpu.ad), so the real vector table lives behind it and
 * hackos_start() points VTOR at it.  Until then interrupts are masked; a fault
 * that early still finds a handler through the copies below.              */
        .section .boot_vectors, "a", %progbits
        .global hackos_boot_vectors
        .type hackos_boot_vectors, %object
hackos_boot_vectors:
        .word   __stack_top             /*  0 initial MSP                 */
        .word   Reset_Handler           /*  1 reset                       */
        .word   nmi_handler             /*  2 NMI                         */
        .word   HardFault_Handler       /*  3                             */
        .word   MemManage_Handler       /*  4                             */
        .word   BusFault_Handler        /*  5                             */
        .word   UsageFault_Handler      /*  6                             */
        .size hackos_boot_vectors, . - hackos_boot_vectors

        .section .vectors, "a", %progbits
        .balign 128                     /* VTOR bits [6:0] are zero       */
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
        .word   svc_handler             /* 11 SVCall     (weak)           */
        .word   debugmon_handler        /* 12                             */
        .word   0                       /* 13 reserved                    */
        .word   pendsv_handler          /* 14 PendSV     (weak)           */
        .word   systick_handler         /* 15 SysTick    (Adder, weak)    */
        .word   uart0_rx_handler        /* 16 IRQ 0: UART0 receive (weak) */
        .rept   31                      /* 17.. external interrupts 1..31 */
        .word   irq_default_handler
        .endr
        .size hackos_vectors, . - hackos_vectors

