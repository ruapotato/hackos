<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# HackOS on the Teensy 4.1

**Status: UNTESTED ON HARDWARE.** Nothing in this port has run on a Teensy.
It builds, it links at the right addresses, and every piece that could be
checked without the board was checked (section 6). The first power-up is
the first real test; section 5 is the order in which to find out what works.

| | |
|--|--|
| Board | PJRC Teensy 4.1: NXP i.MX RT1062 (Cortex-M7, up to 600 MHz), 8 MiB QSPI flash (W25Q64JV), 1 MiB on-chip RAM, microSD socket, optional PSRAM pads (not used) |
| Build | `make BOARD=teensy41 ADDER=../adder` → `build/teensy41/hackos.hex` (and `.elf`, `.bin`) |
| Checks | `make test-teensy ADDER=../adder` (optionally `PJRC_CORES=<checkout of PaulStoffregen/cores>`) |
| Console | LPUART6 = the Teensy's `Serial1`: pin 1 TX, pin 0 RX, 115200 8N1, 3.3 V |
| LED | pin 13 (the orange LED) |
| Storage | the built-in microSD socket at `/sd` (FAT32) |

## 1. What you need

- A Teensy 4.1 and a USB cable (power and programming).
- A **3.3 V** USB-to-serial adapter (FTDI, CP2102, CH340 ...) for the
  console. The Teensy 4.1's pins are not 5 V tolerant. HackOS has no USB
  driver: the USB port only powers the board and talks to PJRC's bootloader.
- PJRC's Teensy Loader (part of Teensyduino) or `teensy_loader_cli`.
- Optional: a microSD card formatted FAT32 (SDHC; FAT12/16 are not
  supported by the FAT code).

## 2. Console wiring

| Adapter | Teensy 4.1 |
|--|--|
| RX | pin 1 (TX1) |
| TX | pin 0 (RX1) |
| GND | GND |

Do not connect the adapter's 5 V or 3.3 V output to the Teensy while it is
powered over USB. Then, for example: `picocom -b 115200 /dev/ttyUSB0`.

## 3. Flashing

```sh
make BOARD=teensy41 ADDER=../adder
teensy_loader_cli --mcu=TEENSY41 -w -v build/teensy41/hackos.hex
```

then press the **program button** on the Teensy (PJRC: "Pressing the button
puts Teensy into programming mode. It is not a 'reset button'"). `-w` waits
for the bootloader to appear. `-s` (soft reboot) does not work: it needs USB
code in the running firmware, which HackOS does not have. The Teensy Loader
GUI works the same way: open the `.hex`, press the button. After
programming, the loader restarts the board. The Teensy 4.1 has no reset
signal; to restart, power-cycle it.

The HEX file covers 0x60000000 to the end of the image (about 380 KB),
inside the 7936 KB the loader accepts (PJRC reserves the top 256 KB of the
flash for EEPROM emulation and the restore program).

**Recovery:** holding the program button for 13 to 17 seconds makes the
Teensy erase its flash and restore PJRC's LED-blink program (PJRC's Teensy
4.1 page). Nothing HackOS does can prevent that; a bad image cannot brick
the board.

## 4. What should happen at the first power-up

In this order. Each step tells you how far the boot got:

1. **The LED lights at once** (within milliseconds of power or of the end of
   programming). `board_reset_early` (boards/teensy41/vectors.S) turns it on
   before anything else. **If it never lights**, the boot ROM did not start
   the image: the boot header, the flash contents, or the image's entry.
2. **The banner on the console:**
   `HackOS 0.3 (milestone 3) -- ARM Cortex-M7, Teensy 4.1 (NXP i.MX RT1062)`.
   **If the LED is on but nothing arrives**, the code runs but the console does
   not: wiring, baud rate, the LPUART6 clock root or the pin mux. The kernel
   carries on regardless (a character that cannot be sent is dropped after
   10 ms), so step 5 still tells you whether the rest boots: slowly, as
   the boot report's ~1,500 characters then take up to 15 s.
3. The file system: either `fat: mounted ...` (a card), or
   `sd: no usable card (error N at CMDm); no /sd`. Without a card the latter
   is expected and harmless.
4. **The boot report**, for example (values are what the ROM leaves; these
   are the first real measurements of the board):
   ```
   clocks as the boot ROM left them (computed from CCM registers):
     PLL1 (ARM)  ...
     core/AHB    ...
     ...
   core clock measured (DWT cycles per SysTick ms): ...
   SYST_CALIB ...  FlexRAM GPR17 555AAAAB GPR16 ... GPR14 ...
   ```
   The two core-clock numbers should agree (one comes from the clock
   registers, the other from counting cycles against SysTick's 100 kHz
   reference). GPR17 should read `555AAAAB`.
5. **The LED starts blinking once a second**: the scheduler runs (a kernel
   thread toggles it every 500 ms).
6. **The shell**: `hamsh — Hamnix shell. Type 'help'.` and the prompt
   `hamsh$ `. Try `ls /bin`, `echo hi | wc`, `ls /sd`.

**A fatal error** prints the fault report on the console and then, instead of
resetting, the LED repeats N short flashes and a pause, N being the exit
code (3 for a fault before the scheduler, the code of `hackos_exit`
otherwise). `halt` resets the board (exit status 0).

## 5. Bring-up checklist (UNTESTED items, in the order to check them)

| # | Item | How to see it | What it rests on now |
|--|--|--|--|
| 1 | The boot ROM accepts the FCB/IVT/boot data and jumps to `Reset_Handler` | LED on | check_boot.py: 47 checks against NXP's structures; the FCB is word for word PJRC's Teensy 4.1 FCB |
| 2 | FlexRAM reconfiguration (GPR17/16/14) before the stack is used | reaching step 2 at all; GPR17 in the report | PJRC's start-up does the same three writes; the bank word is checked against the linker script |
| 3 | `.data` copy from flash, `.bss`/`.xbss` cleared in DTCM | the banner (strings are in flash, but the console state is in `.bss`) | same code as QEMU, different addresses |
| 4 | Watchdogs, SysTick, NVIC reset, I-cache on (`imxrt1062_system_init`) | the system stays up longer than 16 s (WDOG power-down counter) | follows NXP's `SystemInit` |
| 5 | LPUART6: clock root on the 24 MHz oscillator, clock gate, pins 0/1, 115200 | readable banner | driver tested against a register model; constants, gate and pin mux checked against NXP's files and PJRC's pin table |
| 6 | Console input by interrupt (IRQ 25) | typing at the prompt echoes | vector-table entry checked; the handler sequence tested against the model |
| 7 | SysTick on its 100 kHz reference; the scheduler tick | LED blinking at 1 Hz (measure it: 500 ms on, 500 ms off) | PJRC's start-up uses the same reference at 100 kHz |
| 8 | The ROM's clocks | the boot report; compare with a scope on a pin if in doubt | clock arithmetic tested with PJRC's 600 MHz settings and others |
| 9 | MPU: the plan, the regions over FlexSPI2 and SEMC | no fault at start; a process that faults is reported (`ptest peek 20000000`) | same MPU code as QEMU (where isolation is tested), regions per board |
| 10 | Program loading into OCRAM, I-cache invalidated after loading | `ls /bin` runs (every program is loaded, then executed) | loader tested in QEMU; I-cache invalidate is the ARM-documented sequence |
| 11 | The shell in a 448 KB block, programs beside it | the prompt; `ls /bin \| grep h \| head -2 \| wc` | the exact Teensy binaries run in QEMU in the Teensy's memory map (tests/imxrt/t41mem.sh) |
| 12 | uSDHC1 root (PLL2 PFD0 = 396 MHz / 2), pads, card identification | `fat: mounted`; `ls /sd`, `cat` a file | the uSDHC and SD driver passed 21 checks per card against QEMU's own uSDHC and SD card models; pads and clock as SdFat on the Teensy 4.1 |
| 13 | Writing the card | `cp /sd/X /sd/Y`, check on a PC | write path tested against QEMU's card model, written blocks checked from the host |
| 14 | LPI2C1 on pins 18/19 (`t41_i2c_init`) | a device answering (not used at boot) | driver tested against a model, both NACK behaviours |
| 15 | LPSPI4 on pins 10-13 (`t41_spi_init`) | a logic analyser (not used at boot; pin 13 is then no longer the LED) | driver tested against a model |

## 6. What was checked without the board, and what was not

Checked (`make test-teensy`, logs in `build/imxrt/`):

- **Boot header** (`tests/imxrt/check_boot.py`): the FCB, IVT, boot data and
  vector table decoded from the linked image against the structure
  definitions in NXP's `evkmimxrt1060_flexspi_nor_config.h` and
  `fsl_flexspi_nor_boot.h` (offsets computed from the C structs and compared
  with NXP's own offset comments), the read sequence decoded instruction by
  instruction, the HEX file against the binary, every load address in
  flash, the FlexRAM word against the linker's layout, and the FCB against
  PJRC's.
- **Register constants** (`check_regs.py`): every upper-case constant of the
  i.MX RT Adder code against `MIMXRT1062.h` and `fsl_clock.h`, or marked
  `unchecked:` with a reason. It found a wrong clock-gate shift.
- **Pins** (`check_pins.py`): every pin-mux call against NXP's
  `fsl_iomuxc.h` tuple and PJRC's Teensy 4.1 pin table; every pad-control
  value composed from the header's field masks. It found a wrong I2C pad
  value.
- **uSDHC + SD card** (`usdhc_qemu.sh`): the unchanged drivers against
  QEMU's i.MX uSDHC model and SD card model (written by QEMU's developers,
  so not my reading of the manual), SDSC, SDHC and no card.
- **LPUART, LPI2C, LPSPI, GPIO, IOMUXC, clock arithmetic** (`drvtest.sh`):
  against register models I wrote from the reference manual. That proves
  the drivers do what my reading of the manual requires, not that my reading
  is right. They found three driver bugs.
- **Memory** (`t41mem.sh`): the exact `/bin` of the Teensy image, the
  Teensy's tmpfs size, in QEMU with the Teensy's kernel heap (176,176 bytes)
  and program arena (704 KB at a 1 MB boundary), through the shell session
  of `make test`: 26 checks, including a four-stage pipeline beside the
  shell, a 40,000-byte file copied card -> tmpfs -> card, a script run with
  `source`, 12 pipelines in a loop, and a second shell refused cleanly
  (ENOMEM, status 12). This test found two problems that would have stopped
  the board: the general heap's in-band headers made a 448 KB block at the
  arena's start impossible (no shell at all), and page-aligned tmpfs chunks
  fragmented the kernel heap until no program could start after a 40 KB
  file was written. Both are fixed (`mm/parena.ad`, `mm/page_alloc.ad`).

Not covered by anything here: the boot ROM's acceptance of the image, the
clocks the ROM leaves, FlexRAM behaviour, pin electrical behaviour (drive,
pull-ups, levels), all timing (baud rate on the wire, I2C/SPI clocks, SD
clock and its signal integrity), the real LPUART/LPI2C/LPSPI behaviour
where the manual is ambiguous, cache effects (the D-cache is off; the
I-cache is on), interrupt latency, and every real card's behaviour.

## 7. Memory

| Region | Address | Size | Use |
|--|--|--|--|
| Flash | 0x60000000 | 7936 KB usable | boot header, code, constants, the programs of `/bin` (read in place) |
| ITCM | 0x00000000 | 32 KB | the first 4 KB is the null-pointer guard; unused |
| DTCM | 0x20000000 | 288 KB | kernel `.data`/`.bss` (~40 KB, 25 KB of it the thread table), tmpfs table (44 KB), stacks (18 KB), kernel heap (172 KB): kernel stacks of threads and processes (16 KB per process), pipes, **the data of files in `/`** |
| OCRAM | 0x20200000 | 704 KB | the program arena (OCRAM2 512 KB + 6 FlexRAM banks as OCRAM) |

The shell (with `boards/teensy41/patches/user/hamnix/hamsh.ad.patch`) is
183 KB of code, 1.3 KB of data and 219 KB of tables, plus a 32 KB stack: a
448 KB block, 7/8 of a 512 KB MPU region, which must start at 0x20200000.
That leaves 256 KB for the programs it runs; `grep` (patched) is the
largest at 192 KB.

Consequences, each a limit of this board without PSRAM:

- **One shell.** A second `hamsh` (a script run as `hamsh FILE`) does not
  fit; `source FILE` runs a script in the running shell.
- **Files in `/` (tmpfs) share the kernel heap** with kernel stacks: a few
  tens of KB of files in `/tmp` is the practical limit (a file is at most
  256 KB by the tmpfs patch). Large files belong on `/sd`.
- The shell's limits are 1/16 of Hamnix's (256 AST nodes and values, 8 KB of
  strings, 256 tokens per input line, 4 lines of history): enough for
  interactive use and short scripts; a long script can hit "arena
  exhausted".

**PSRAM** (an 8 MB APS6404L on the Teensy 4.1's pads, on FlexSPI2 at
0x70000000) would remove all three: the program arena could be megabytes,
the shell could keep its QEMU sizes, and `grep` its tables. It needs a
FlexSPI2 driver (pin mux, clock, LUT for the PSRAM's commands) and a decision
about caching; nothing of that exists. It is **not required** for the
shell and the coreutils at the sizes above; it **is** required for the
compiler on the device (milestone-3 report, section 14) and for anything
with a working set beyond ~256 KB.

## 8. Notes for the HackerSlide board (i.MX RT1176)

`soc/imxrt/` (LPUART, LPI2C, LPSPI, GPIO, uSDHC, IOMUXC call form, delay)
is meant to be shared. `check_regs.py --compare` against NXP's
`MIMXRT1176_cm7.h` (same SDK commit): 182 of its constants are identical
there, none differ; the RT1176's uSDHC has two registers more
(`STROBE_DLL_CTRL/STATUS`) and **no burst-length fields in WTMK_LVL**
(`RD_BRST_LEN`/`WR_BRST_LEN` are absent from its header: write 0 there on
the RT1176). The LPUART, LPI2C, LPSPI and GPIO register blocks are identical
in layout.

Not shared, per SoC (a `soc/imxrt1176/` next to `soc/imxrt1062/`): the clock
controller (the RT1176's CCM has `CLOCK_ROOTn` registers and LPCG gates, not
CCGRs and CSCDRs), IOMUXC pad names and pad-control bits, FlexRAM control
(GPR registers differ), the watchdog set, the boot header's flash
configuration, the vector table length, and the M7's maximum clock for
`delay_init` (1000 MHz).
