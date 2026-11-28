/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- vector table for the Adafruit Feather nRF52840 Express
 * (Nordic nRF52840); included by arch/armv7m/startup.S.
 * UNTESTED ON HARDWARE.
 *
 * This table is the first thing of the image, at the application start
 * address of Adafruit's UF2 bootloader with SoftDevice S140 6.1.1 (0x26000,
 * link.ld).  The bootloader starts an application by reading word 0 (MSP)
 * and word 1 (reset) from there (bootloader_util.c); it also accepts the
 * image as valid only if word 0 is in RAM and word 1 a Thumb address inside
 * the application area (bootloader.c, bootloader_app_is_valid).  The MBR's
 * and SoftDevice's interrupt forwarding is not used: hmicro_start sets VTOR
 * to this table, so exceptions come here directly.
 *
 * 16 system entries + 48 interrupts (nrf52840.h: the last IRQn is
 * SPIM3_IRQn = 47); 256 bytes, VTOR-aligned (the power of two above the
 * size).                                                                */
        .section .vectors, "a", %progbits
        .balign 256
        .global hmicro_vectors
        .type hmicro_vectors, %object
hmicro_vectors:
        .word   __stack_top             /*  0 initial MSP                 */
        .word   Reset_Handler           /*  1 reset                       */
        .word   nmi_handler             /*  2 NMI                         */
        .word   HardFault_Handler       /*  3                             */
        .word   MemManage_Handler       /*  4                             */
        .word   BusFault_Handler        /*  5                             */
        .word   UsageFault_Handler      /*  6                             */
        .word   0, 0, 0, 0              /*  7..10 reserved                */
        .word   svc_handler             /* 11 SVCall                      */
        .word   debugmon_handler        /* 12                             */
        .word   0                       /* 13 reserved                    */
        .word   pendsv_handler          /* 14 PendSV                      */
        .word   systick_handler         /* 15 SysTick (not started here)  */
        .word   irq_default_handler     /* IRQ 0: CLOCK_POWER             */
        .word   irq_default_handler     /* IRQ 1: RADIO                   */
        .word   uart0_rx_handler        /* IRQ 2: UARTE0 = the console    */
        .rept   14                      /* IRQ 3..16                      */
        .word   irq_default_handler
        .endr
        .word   board_rtc1_handler      /* IRQ 17: RTC1 = scheduler tick  */
        .rept   30                      /* IRQ 18..47                     */
        .word   irq_default_handler
        .endr
        .size hmicro_vectors, . - hmicro_vectors
