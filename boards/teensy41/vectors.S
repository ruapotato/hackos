/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS -- Teensy 4.1 (NXP i.MX RT1062): boot header, vector table, and the
 * code that must run before the stack exists.  Included by
 * arch/armv7m/startup.S.  UNTESTED ON HARDWARE.
 *
 * The boot ROM, booting from the FlexSPI NOR flash (the Teensy 4.1's
 * W25Q64JV at 0x60000000), reads:
 *   0x60000000  the FlexSPI configuration block (FCB, 512 bytes): how to
 *               talk to the flash.  The values are those of PJRC's Teensy 4.1
 *               core (teensy4/bootdata.c), which every Teensy 4.1 boots with,
 *               written out per field of NXP's flexspi_nor_config_t
 *               (evkmimxrt1060_flexspi_nor_config.h).  The read sequence is
 *               the W25Q64JV's Fast Read Quad I/O (0xEB); it needs the
 *               flash's QE bit set, which it is on a Teensy (PJRC's FCB
 *               relies on the same).
 *   0x60001000  the image vector table (IVT, NXP's ivt in
 *               fsl_flexspi_nor_boot.h): header 0xD1 / 32 bytes / version
 *               4.1, entry = Reset_Handler (Thumb address, as PJRC's), the
 *               address of the boot data and of the IVT itself; no DCD, no
 *               CSF (an unsigned image; the Teensy 4.1 is not locked).
 *   0x60001020  boot data: image start 0x60000000, image length, plugin 0.
 * tests/imxrt/check_boot.py decodes all three from the linked image against
 * NXP's structure definitions and compares the FCB with PJRC's.
 *
 * The ROM jumps to the entry with the core clock it chose and its own stack
 * in OCRAM.  board_reset_early then configures FlexRAM -- 1 bank of 32 KB
 * ITCM, 9 banks (288 KB) DTCM, 6 banks (192 KB) OCRAM after OCRAM2, see
 * link.ld -- before Reset_Handler points the stack into DTCM, and
 * lights the LED (pin 13) as the first sign of life.                     */

#define BOARD_RESET_EARLY 1

        .section .flashconfig, "a", %progbits
        .global hackos_fcb
hackos_fcb:
        .word   0x42464346        /* 0x000 tag "FCFB" */
        .word   0x56010000        /* 0x004 version 1.0.0 (PJRC's value) */
        .word   0x00000000
        .word   0x00020101        /* 0x00C readSampleClkSrc=1 (DQS loopback), csHoldTime=1, csSetupTime=2, columnAddressWidth=0 */
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x01060401        /* 0x044 deviceType=1 serial NOR, sflashPadType=4, serialClkFreq=6 (100 MHz), lutCustomSeqEnable=1 */
        .word   0x00000000
        .word   0x00000000
        .word   0x00800000        /* 0x050 sflashA1Size = 8 MiB (W25Q64JV) */
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x0A1804EB        /* 0x080 LUT seq 0 (read): CMD_SDR(1 pad, 0xEB) RADDR_SDR(4 pads, 24) */
        .word   0x32041EFF        /* 0x084           MODE8_SDR(4 pads, 0xFF) DUMMY_SDR(4 pads, 4) */
        .word   0x00002601        /* 0x088           READ_SDR(4 pads, 1) STOP */
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000100        /* 0x1C0 pageSize 256 */
        .word   0x00001000        /* 0x1C4 sectorSize 4096 */
        .word   0x00000001        /* 0x1C8 ipcmdSerialClkFreq=1 (30 MHz) */
        .word   0x00000000
        .word   0x00010000        /* 0x1D0 blockSize 64 KiB */
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .word   0x00000000
        .size hackos_fcb, . - hackos_fcb

        .section .ivt, "a", %progbits
        .global hackos_ivt
        .type hackos_ivt, %object
hackos_ivt:
        .word   0x412000D1              /* tag 0xD1, length 0x0020, version 0x41 */
        .word   Reset_Handler           /* entry (Thumb bit set by the linker) */
        .word   0                       /* reserved1 */
        .word   0                       /* dcd: none */
        .word   hackos_boot_data        /* boot_data */
        .word   hackos_ivt              /* self */
        .word   0                       /* csf: none (unsigned image) */
        .word   0                       /* reserved2 */
        .size hackos_ivt, . - hackos_ivt

        .section .bootdata, "a", %progbits
        .global hackos_boot_data
        .type hackos_boot_data, %object
hackos_boot_data:
        .word   0x60000000              /* start of the image */
        .word   __flash_image_len       /* its length */
        .word   0                       /* plugin: no */
        .word   0xFFFFFFFF              /* placeholder (NXP's g_boot_data) */
        .size hackos_boot_data, . - hackos_boot_data

/* The vector table VTOR is pointed at (16 system entries + 158 interrupts,
 * MIMXRT1062.h NUMBER_OF_INT_VECTORS = 174; aligned to 1 KB, the power of two
 * above its size, as VTOR requires).  The ROM does not read it: the IVT's
 * entry is the reset handler.                                            */
        .section .vectors, "a", %progbits
        .balign 1024
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
        .word   svc_handler             /* 11 SVCall                      */
        .word   debugmon_handler        /* 12                             */
        .word   0                       /* 13 reserved                    */
        .word   pendsv_handler          /* 14 PendSV                      */
        .word   systick_handler         /* 15 SysTick                     */
        .rept   25                      /* IRQ 0..24                      */
        .word   irq_default_handler
        .endr
        .word   uart0_rx_handler        /* IRQ 25: LPUART6 = the console  */
        .rept   132                     /* IRQ 26..157                    */
        .word   irq_default_handler
        .endr
        .size hackos_vectors, . - hackos_vectors

/* board_reset_early: called by Reset_Handler with interrupts masked, before
 * the stack pointer is set (it uses no stack; r0-r3 only).
 *   FlexRAM (PJRC's start-up does the same three writes, in this order):
 *     IOMUXC_GPR_GPR17 = __flexram_bank_config (link.ld): 2 bits per 32 KB
 *                        bank, 11 = ITCM, 10 = DTCM, 01 = OCRAM
 *     IOMUXC_GPR_GPR16 |= FLEXRAM_BANK_CFG_SEL (use GPR17, not the fuses),
 *                        INIT_ITCM_EN, INIT_DTCM_EN (VTOR field kept)
 *     IOMUXC_GPR_GPR14 TCM size fields (bits 23:16) = 0xAA: 512 KB address
 *                        windows for both (reference manual; not in NXP's
 *                        device header); the other bits kept
 *   LED: pad GPIO_B0_03 (Teensy pin 13) to ALT5 = GPIO2_IO03, 3-state
 *     pad control DSE 7, GPIO2 clock gate on, output high.               */
        .section .text.board_reset_early, "ax", %progbits
        .global board_reset_early
        .thumb_func
        .type   board_reset_early, %function
board_reset_early:
        ldr     r0, =0x400AC000         /* IOMUXC_GPR */
        ldr     r1, =__flexram_bank_config
        str     r1, [r0, #0x44]         /* GPR17 */
        ldr     r1, [r0, #0x40]
        orr     r1, r1, #7              /* GPR16: BANK_CFG_SEL|DTCM_EN|ITCM_EN */
        str     r1, [r0, #0x40]
        ldr     r1, [r0, #0x38]
        bic     r1, r1, #0x00FF0000
        orr     r1, r1, #0x00AA0000     /* GPR14: ITCM and DTCM windows 512 KB */
        str     r1, [r0, #0x38]
        dsb
        isb
        ldr     r0, =0x400FC068         /* CCM_CCGR0 */
        ldr     r1, [r0]
        orr     r1, r1, #0xC0000000     /* CG15: GPIO2 */
        str     r1, [r0]
        ldr     r0, =0x401F8148         /* SW_MUX_CTL_PAD_GPIO_B0_03 */
        movs    r1, #5                  /* ALT5: GPIO2_IO03 */
        str     r1, [r0]
        ldr     r0, =0x401F8338         /* SW_PAD_CTL_PAD_GPIO_B0_03 */
        movs    r1, #0x38               /* DSE = 7, as PJRC */
        str     r1, [r0]
        ldr     r0, =0x401BC000         /* GPIO2 */
        ldr     r1, [r0, #0x04]
        orr     r1, r1, #8              /* GDIR bit 3: output */
        str     r1, [r0, #0x04]
        movs    r1, #8
        str     r1, [r0, #0x84]         /* DR_SET bit 3: LED on */
        bx      lr
        .size   board_reset_early, . - board_reset_early
        .ltorg
