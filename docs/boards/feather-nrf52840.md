<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Hamnix Micro on the Adafruit Feather nRF52840 Express

`make BOARD=feather-nrf52840` builds Hamnix Micro for the Adafruit Feather nRF52840
Express (product 4062: Nordic nRF52840, 64 MHz Cortex-M4F with a
single-precision FPU and an 8-region MPU, 1 MB flash, 256 KB RAM, 2 MB QSPI
flash, Adafruit's UF2 bootloader).

**Nothing here has run on a Feather. Every hardware-facing piece is UNTESTED
ON HARDWARE.** The same image, unchanged, boots and runs the whole shell
session in Renode's nRF52840 machine (section 6). That is the strongest
check available without the board. It is not proof that the board behaves the same.

The Feather nRF52840 **Sense** has the same chip, the same TX/RX pins and
the same bootloader layout, but its red LED is on P1.09 and it has no
32 kHz crystal. Hamnix Micro reads the board id from the bootloader's
configuration block and picks the LED pin from that, and it runs the low-frequency clock
from the internal RC oscillator on both boards. Sense support is optional
and is even less tested than the Express.

## 1. What you need

- The Feather nRF52840 Express and a USB cable. USB only powers the board
  and talks to the bootloader. Hamnix Micro has no USB driver, so its console is
  the TX/RX header pins, not the USB port.
- A 3.3 V USB-to-serial adapter, the main console method (section 2). A
  Raspberry Pi 3 can stand in for it.
- On the PC: `make BOARD=feather-nrf52840` output, and `picocom` or `screen`.
- Optional: a Raspberry Pi Pico as an SWD probe (section 7).

## First run on a real board (2026-11-28) and the old-bootloader limit

A Feather nRF52840 Express with **Adafruit bootloader 0.2.6** (2018,
`INFO_UF2.TXT`: "UF2 Bootloader 0.2.6 ... s140 6.1.1") did not start the
first images: the chip reset in a loop. The cause was not in the kernel.
Bootloader 0.2.6 has `USER_FLASH_END 0xAD000` (its `src/usb/uf2/uf2cfg.h`)
and **silently drops every UF2 block at or above 0xAD000**. The image then
ended at 0xBD000 with `/bin` at 0x80000, so the end of `/bin` and all of
`.data`'s initial values were never written: every initialised global read
as erased flash (0xFFFFFFFF) and the first register write through one
(`CLOCK_BASE + CLOCK_INTENCLR`) was a bus fault at 0xFFFFFFFE, then a CPU
lock-up reset. Renode loads the ELF, so it could not show this.

Fix: `/bin` moved to 0x60000 and the whole image must end below 0xAD000
(`__uf2_limit`: an ASSERT in `link.ld` and a check in
`tests/nrf52/check_image.py`). The MPU region for `/bin` is now computed
from where the table lies (`board_mpu_xip_*`), with the sub-regions outside
it disabled.

Run on that board with this layout, **milestone-3 image only** (console on
TX/RX at 115200 through a USB-serial cable): the boot report (`part
0x00052840`, 256 KB RAM, HFCLK from the crystal), the shell, typing and
echo, `ls /bin`, `echo one two three | wc`, a four-program pipeline,
`echo saved > /tmp/f` and `cat`, and `ptest peek 20000000` ending with
status 139 (the MPU on the real Cortex-M4). Not yet run on the board:
anything added in milestone 4 (the editor, the extra programs, tickless
idle and suspend, pasted input), Ctrl-C, timing accuracy, current draw.

Second fault found on the board (2026-11-28): `sleep 2` never returned and
`/proc/uptime` stood still. The RTC compare for the next tick could be
written when the counter had already moved to within one count of it, and
then COMPARE does not fire until the counter wraps (512 s). `_aim` in
`soc/nrf52/rtc.ad` now reads the counter back after the write and tries
again, and pends the interrupt if it cannot get 2 counts ahead. **This fix
has passed the emulator suites only; it has not run on the board yet.**

`halt uf2` restarts into the bootloader's drive (GPREGRET = 0x57), so a new
image can be copied without the reset button. Also not yet tried on the
board.

How it was found without a debugger, for the next board: the bootloader's
drive exposes the application flash as `CURRENT.UF2`, so a build that
writes words into a reserved erased page (NVMC) at each start-up stage and
in the fault handler (exception number, CFSR, BFAR, stacked PC) can be read
back over USB after a double-tap.

Size is a constraint on such boards. The milestone-4 image ended at 0xaa288, 11 KB below the limit; the milestone-5 image is built with `-Oz` and ends at 0xa0af0, 49 KB below it (section 7a, "Milestone 5 update"). Newer Adafruit bootloaders
raise the limit to 0xED000; updating the bootloader is the board owner's
decision.

## 2. Console wiring

The console is UARTE0 at **115200 baud, 8N1**, 3.3 V logic, no flow control:

| Feather pin | nRF52840 | direction |
|--|--|--|
| **TX** | P0.25 | Hamnix Micro sends |
| **RX** | P0.24 | Hamnix Micro receives (pulled up inside, so an open input reads idle) |
| **GND** | | common ground |

(Adafruit's Arduino variant: Serial1 TX = D0 = P0.25, RX = D1 = P0.24;
`tests/nrf52/check_image.py` compares.)

### 2a. With a USB-to-serial adapter (main method)

1. Set the adapter to **3.3 V logic** (a jumper or switch on many adapters).
   5 V logic can damage the nRF52840.
2. Wire it **crossed over**:
   - adapter **TX** to Feather **RX**
   - adapter **RX** to Feather **TX**
   - adapter **GND** to Feather **GND**
3. **Do not connect the adapter's 5 V or VCC pin** while the Feather is
   powered from USB. Power the Feather from its own USB port.
4. On the Linux PC, your user must be in the `dialout` group (once:
   `sudo usermod -aG dialout $USER`, then log out and in again). Then:

   ```sh
   picocom -b 115200 /dev/ttyUSB0        # leave with Ctrl-A Ctrl-X
   # or
   screen /dev/ttyUSB0 115200            # leave with Ctrl-A k
   ```

   The adapter may appear as `/dev/ttyACM0` instead (`ls /dev/tty{USB,ACM}*`
   before and after plugging it in). Ctrl-C reaches Hamnix Micro through both
   programs.

### 2b. With a Raspberry Pi 3 (alternative)

The Pi 3's header UART is 3.3 V too. Wire it crossed over:

| Pi 3 header | | Feather |
|--|--|--|
| pin 8, GPIO14 (TXD) | to | **RX** |
| pin 10, GPIO15 (RXD) | to | **TX** |
| pin 6, GND | to | **GND** |

Do not connect the Pi's 5 V or 3.3 V pins to the Feather. Power the
Feather from USB. On the Pi:

1. `sudo raspi-config`, then *3 Interface Options*, then *I6 Serial Port*.
   Answer **No** to "Would you like a login shell to be accessible over
   serial?" and **Yes** to "Would you like the serial port hardware to be
   enabled?". Reboot. (This sets `enable_uart=1`. On a Pi 3 the header
   UART is the mini UART, whose baud rate follows the VPU clock, and
   `enable_uart=1` fixes that clock. To use the PL011 UART instead, add
   `dtoverlay=disable-bt` to `/boot/firmware/config.txt` and run
   `sudo systemctl disable hciuart`. Raspberry Pi's documentation,
   "Configure UARTs", covers both.)
2. `sudo apt install picocom` (or `screen`), then:

   ```sh
   picocom -b 115200 /dev/serial0
   # or
   screen /dev/serial0 115200
   ```

## 3. Flashing (UF2 drag and drop)

`make BOARD=feather-nrf52840` writes `build/feather-nrf52840/hmicro.uf2`
(and `.hex`, `.bin`, `.elf`).

1. Plug the Feather into USB and **double-tap its reset button** (two
   presses within half a second; the bootloader's window is 500 ms,
   `DFU_DBL_RESET_DELAY`). A USB drive appears. On the Express it is named **FTHR840BOOT**, on the Sense
   FTHRSNSBOOT. (The name comes from Adafruit's bootloader,
   `UF2_VOLUME_LABEL`. Some tutorials call it FEATHERBOOT.)
2. **Check `INFO_UF2.TXT` on the drive.** It must say `SoftDevice: S140 6.1.1`,
   which is what the Feather nRF52840 ships with: applications start at 0x26000.
   If it names S140 7.x, build with `make BOARD=feather-nrf52840
   NRF_APP_START=0x27000` instead (and change `FLASH ORIGIN` in
   `boards/feather_nrf52840/link.ld` to match; the link stops with an error
   when the two disagree).
3. Copy the file and flush:

   ```sh
   cp build/feather-nrf52840/hmicro.uf2 /media/$USER/FTHR840BOOT/ && sync
   ```

   The drive disappears and the board restarts into Hamnix Micro. An error from
   the file manager at that moment is normal.

What the UF2 file touches: only 0x26000 up to the end of the image (about
0xBD000). The MBR (0..0x1000), the SoftDevice (0x1000..0x26000), the
40 KB application-data area at 0xEA000, the bootloader at 0xF4000 and its
settings stay as they were (`tests/nrf52/check_image.py` checks every
block's address). To go back to Arduino or CircuitPython, double-tap reset
and copy their UF2 in the same way.

Each later flash needs a double-tap. A single tap of reset restarts Hamnix Micro.
The `halt` program (`halt 0` at the prompt) also restarts it, through the
bootloader.

## 4. What should happen at the first power-up

1. **The red LED (D3, P1.15) lights at once.** That is
   the very first thing Hamnix Micro does after setting up memory. If it stays
   dark, Hamnix Micro never ran (section 5, step 1).
2. Within a fraction of a second the console shows this (the Renode
   run's transcript, `build/nrf52/renode/console.txt`, shortened):

   ```
   Hamnix Micro 0.3 (milestone 3) -- ARM Cortex-M4F, Adafruit Feather nRF52840 Express (Nordic nRF52840)
   chip: part 0x00000000 variant 0x00000000, 0 KB RAM, 0 KB flash, device id 0x00000000 0x00000000
   reset reason 0x00000000, bootloader board id 0x00000000 (unknown: assuming the Express, red LED P1.15)
   clocks: HFCLK from the 32 MHz crystal, LFCLK from the RC oscillator
   /bin in place at 0x00060000..0x0009c8a8, MPU window 1024 KB
   memory: kernel heap 7216 of 50640 bytes in use at boot; program arena 0x20018000..0x20040000
   hamsh — Hamnix shell. Type 'help'.
   hamsh$
   ```

   In Renode the FICR, the reset reason and the bootloader's flash read zero.
   On the board expect `part 0x00052840`, `256 KB RAM, 1024 KB flash`, a
   non-zero reset reason (bit 0 = the reset pin, bit 2 = a soft reset,
   0 after power-on), and `bootloader board id 0x239a0029 (Feather
   nRF52840 Express ...)`. "unknown" there means the bootloader has no
   configuration block at 0xFD800 (an old bootloader); the Express LED is
   used then.
3. **The red LED then blinks at 1 Hz**: the scheduler and its RTC1 tick are running.
4. `ls /bin`, `echo hi | wc`, `cat /bin/hello | wc` should work as in section 6.
5. After a fatal kernel error the LED repeats N short flashes and a pause
   (N = the exit code, at most 9) instead of resetting. The report is on
   the console.

## 5. Bring-up checklist (UNTESTED items, in the order to check them)

1. **LED on at power-up.** If it stays dark:
   - Is the UF2 right for the SoftDevice (step 2 of section 3)?
   - Does the bootloader start the image? Its rule (`bootloader_app_is_valid`)
     is word 0 in RAM and word 1 a Thumb address in the application area.
     `check_image.py` checks both.
   - Next look with SWD (section 7): halt the core, read PC, VTOR
     (0xE000ED08 should be 0x26000) and `CFSR` (0xE000ED28).
2. **Console output.** Check the wiring (crossed over, GND) and 115200 8N1.
   Garbage instead of text means the baud is wrong. Look for the clocks line:
   "HFXO did NOT start" means the core and the UART run on the internal
   oscillator (+-1.5 %), which usually still works at 115200.
3. **Typing.** Characters must echo (the shell echoes). If output works but
   input does not: the RX wire, or the UARTE receive interrupt (IRQ 2;
   `uarte_rx_irq_enable`).
4. **LED blinking at 1 Hz.** If it lights but never blinks, the scheduler
   tick (RTC1 on LFCLK) is not running. The clocks line says whether LFCLK started.
5. **Shell commands and pipelines** (`ls /bin | grep h | head -2 | wc`),
   then **Ctrl-C** on `ptest loop`, then **a fault** (`ptest peek 20000000`
   must end with status 139: the MPU, on the real M4).
6. **Timing.** `sleep`-like waits use the RTC1 tick, 1000 Hz on average, from
   the RC oscillator, which Hamnix Micro does not calibrate: expect an error of
   up to a few per cent against a wall clock (the product specification's
   LFRC tolerance).

## 6. What was checked without the board, and what was not

`make test-nrf52 ADDER=../adder` runs all of it: `tests/nrf52/run_all.sh`,
with logs in `build/nrf52/`.

| Check | What it covers |
|--|--|
| Renode 1.17.1 (`tests/nrf52/renode_session.sh`) | The unchanged ELF in Renode's nRF52840 models (Cortex-M4F, NVIC, MPU, UARTE0 with EasyDMA, RTC1, CLOCK, GPIO), started like the bootloader starts it (MSP and PC from 0x26000). A typed shell session: builtins, `ls`, pipelines of 2 to 5 programs beside the shell, a sixth refused cleanly, `>`, `>>`, `<`, cp/mkdir/rm, exit status, a program copied to /tmp and run from RAM, an MPU fault (139), Ctrl-C (130), a script with `source`, 12 pipelines in a loop, a second shell refused (ENOMEM), soft-double results equal to the Cortex-M7's hardware ones, `halt 0` |
| `check_regs.py` | Every register address, offset, bit field and value, and every interrupt number, against Nordic's `nrf52840.h`/`_bitfields.h` (the struct layouts computed and checked against the header's size comments); the vector count against the header's last IRQn. It found one error: the UARTE baud value (fixed) |
| `check_image.py` | Vector table at 0x26000, MSP and reset as the bootloader requires, no single-tap magic at 0x26200, HEX and UF2 only inside 0x26000..0xEA000, UF2 block format (also byte-identical to Microsoft's `uf2conv.py` output), the /bin MPU window, pins and bootloader constants against `feather_facts.txt` |
| `extract_facts.py` | Re-extracts those facts from Adafruit's bootloader and Arduino sources when `ADAFRUIT_BOOTLOADER=`/`ADAFRUIT_ARDUINO=` are given. The SoftDevice's own size word gives the application start (0x26000 for 6.1.1, 0x27000 for 7.3.0) |
| code check | No double-precision FPU instruction anywhere (the M4F has none); the shell links compiler-rt's soft double; every program is an RWPI executable with no load-time relocation |

**Not covered:** Adafruit's bootloader itself (Renode starts the image
directly); real UART timing and the RX FIFO behaviour between two DMA
transfers; the crystal oscillators (Renode's CLOCK model just reports them
started); the RC oscillator's accuracy; sleep in WFI (the tick is RTC1
because SysTick stops in WFI on the nRF52; Renode models neither the stop
nor sleep, so this choice rests on the chip's documented behaviour, not on
the emulator); the FICR and UICR contents and the bootloader's
configuration block (they read zero in Renode); electrical levels; flash
wait states and the instruction cache; APPROTECT.

## 7. SWD debugging (optional)

The Feather has a **2x5 pin 0.05" SWD header** populated (Adafruit: "SWD
Connector"). It is the standard ARM 10-pin Cortex Debug layout: 1 VTref (3.3 V),
2 SWDIO, 3 GND, 4 SWCLK, 5 GND, 6 SWO, 7 key, 8 NC, 9 GND, 10 nRESET. Check the pin-1 mark on the board.

**A Raspberry Pi Pico as the probe**, with Raspberry Pi's `debugprobe`
firmware (MIT; github.com/raspberrypi/debugprobe):

1. Get `debugprobe_on_pico.uf2` from its releases page (or build it with
   `cmake -DPICO_BOARD=pico`). Hold BOOTSEL on the Pico, plug it in, and copy
   the file to the RPI-RP2 drive.
2. Wire it (`include/board_pico_config.h`): Pico **GP2 = SWCLK** to header
   pin 4, Pico **GP3 = SWDIO** to header pin 2, Pico GND to header pin 3,
   optionally Pico **GP1** (reset) to pin 10. The Pico's **GP4 (UART TX)
   and GP5 (UART RX)** are also a USB serial port: GP4 to Feather RX, GP5 to
   Feather TX, and the console appears as `/dev/ttyACM0`.
3. With OpenOCD:

   ```sh
   openocd -f interface/cmsis-dap.cfg -c "transport select swd" -f target/nrf52.cfg
   # flash the HEX this way instead of UF2 (it covers only 0x26000..):
   openocd -f interface/cmsis-dap.cfg -c "transport select swd" -f target/nrf52.cfg \
           -c "program build/feather-nrf52840/hmicro.hex verify reset exit"
   ```

   Then `gdb-multiarch build/feather-nrf52840/hmicro.elf` with `target extended-remote :3333`.

**The QT Py RP2040** has no ready-made debugprobe build. It would need its own
board header (as `include/board_example_config.h`) naming two of its pads
as SWCLK and SWDIO, built with the Pico SDK. Not tried; use the Pico.

**APPROTECT.** nRF52840s from build code F on close the debug port at each
reset unless the running firmware opens it. Hamnix Micro does what Nordic's
start-up does: it copies `UICR.APPROTECT` into `APPROTECT.DISABLE`, so a
chip whose UICR holds 0x5A ("hardware disabled") stays open. What the UICR
of a given Feather holds is not known here (Adafruit's bootloader source
does not set it). If OpenOCD cannot connect, OpenOCD's `nrf52_recover`
command (in recent OpenOCD releases) opens the chip by **erasing all of
it, bootloader included**. The bootloader can then be
restored over SWD from Adafruit's `*_bootloader-*_s140_6.1.1.hex`.

## 7a. Memory

256 KB of RAM holds everything. Programs' **code stays in flash** (the
ROM table at 0x60000, run in place). Only their data and stacks are in RAM.
Figures from `make BOARD=feather-nrf52840` and the Renode session's memory
report (printed at `halt`):

| RAM | bytes |
|--|--|
| .data + .bss (thread table 16 x 816, tmpfs table 32 entries, open-file table, ...) | 1,712 + 11,008 + 24,424 |
| handler stack + fault stack | 8,192 + 2,048 |
| kernel heap (0x2000B920..0x20017F00) | 50,640 (7,216 in use at boot, 39,456 peak in the session) |
| program arena (0x20018000..0x20040000) | 163,840 |

| Program | code (flash) | data+bss | stack | block in the arena |
|--|--|--|--|--|
| hamsh | 208,406 | 104,144 | 8,192 (1,760 used) | 114,688 (7/8 of 128 KB, at 0x20020000) |
| grep | 10,555 | 6,736 | 8,192 (7,032 used) | 16,384 |
| ptest | 9,789 | 18,640 | 4,096 | 24,576 |
| cp | 3,631 | 12,848 | 4,096 | 20,480 |
| ls | 3,582 | 4,704 | 4,096 | 10,240 |
| cat, wc, echo, head, rm, mkdir, hello, halt | < 1,300 | < 150 | 4,096 | 5,120 |

Each process also takes a 4 KB kernel stack (up to 2,156 bytes used in the
session) and 816 bytes of thread table. Each pipe takes 1 KB, each KB of a
file in / takes a 1 KB chunk, and an exec takes a transient 1 KB argument
buffer, all from the kernel heap.

**What fits** (all checked in Renode): the kernel, the shell, and a
pipeline of **five programs** beside it (`ls /bin | cat | cat | cat | wc`,
`ls /bin | grep h | head -2 | wc`). A **sixth** program in a pipeline does
not fit: its kernel stack cannot be had, and the shell says "command not
found" for it. Small files in /: 32 entries, 64 KB per file at most.

**What does not fit:** a second shell (`hamsh FILE` fails with ENOMEM; use
`source FILE`); cp or ptest alongside grep in one pipeline (each needs the
one 32 KB-aligned gap); the shell at its Teensy or QEMU sizes. The per-board
size patches in `boards/feather_nrf52840/patches/` make the shell's tables
smaller: 512-byte input lines, 128 tokens, 64 argv words, 8 environment
variables, 16 functions, a 2-line history, 4 KB of interned strings. grep's
regex is limited to 64 nodes. Long or complex scripts can hit "arena
exhausted". There is no /sd: the Feather has no card socket.

**The 2 MB QSPI flash is not used.** It is not needed for the shell and
coreutils, since code runs from the internal flash, which has about
236 KB free between the kernel (ending at 0x45098) and /bin (0x80000), and
180 KB above the image (0xBD000..0xEA000). What it would take, as read-only program storage or a small FAT:
a QSPI driver (`NRF_QSPI`: pins P0.19 SCK, P0.20 CS, P0.17/22/23/21 IO0-3
per Adafruit's variant; GD25Q16C commands), a block device for
`kernel/block/blk.ad`, and either (a) FAT on it, with programs loaded
from it copied into RAM (the RWPI loader already copies code when a file
is not in the ROM table), or (b) XIP: the QSPI peripheral maps the flash at
0x12000000 for execution, which would need a second MPU window and the
loader to run code there. Renode has no QSPI model, so either would be
untested.

### Milestone 4 update (measured in Renode, 2026-11-27)

| | bytes |
|--|--|
| flash: kernel text | 170,688 (was 126,920) |
| flash: `/bin`, 33 programs run in place | about 300,600 (was 247,976) |
| `.data` / `.bss` and tables | 1,888 / 36,488 |
| kernel heap | 49,408; 7,216 in use at boot; 39,000-42,700 at the session's peak |
| program arena | 163,840 (unchanged) |

Beside the shell (114,688 bytes) the arena has one 32 KB and one 16 KB gap.
New programs: `vi` 24 KB (it edits 200 lines of 79 characters here), `sort`
24 KB (48 lines), `tail` 20 KB, `cut` 16 KB, the rest 5-10 KB. So: the shell
plus **one** of `vi`, `sort`, `grep`, `ptest`; or a pipeline of small
programs (start the biggest stage first: `sort < f | head`, not
`cat f | sort`). The kernel heap is the binding limit late in a long
session: 4 KB per process, 1 KB per pipe, 2 KB and up per file in `/`.
The init thread's stack is 4 KB (2,460 bytes used). The halt report now
lists the kernel threads' stacks, the console's counters and a guard word
behind the UART's DMA buffer.

Power: tickless idle on RTC1 (about 6.6 processor wake-ups per second at an
idle shell in Renode, 1000 with the periodic tick); `suspend [SECONDS] [-n]`
(docs/power.md). Console flow control: XON/XOFF by default (`picocom --flow
x`), optional RTS (`CONSOLE_RTS_PIN` in `boards/feather_nrf52840/board.ad`).
All UNTESTED ON HARDWARE; add to the bring-up checklist: paste a block of
text, `idlestat 5`, `suspend 10`, `suspend 10 -n` with a current meter.

### Milestone 5 update: size, pins, 9P (measured in Renode, 2026-11-28)

**Nothing in this section has run on the board.** The image that ran on
the real Feather was built at `-O2`; this one is built at `-Oz` (every C
and Adder unit, kernel and programs), which changes inlining and stack use
everywhere. The emulator suites pass; the stacks measured in Renode are
below.

**Flash.** With namespaces, device files and 9P the `-O2` kernel grew to
228 KB and `/bin` to 323 KB: 70 KB over the bootloader's 0xAD000. Measured
alternatives for kernel / `/bin`: `-O2` 228 / 323 KB, `-Os` 164 / 323 KB,
`-Oz` 127 / 271 KB (the full program set). `board.mk` now sets `OPT ?= -Oz`.

| | address | bytes |
|--|--|--|
| kernel code and constants | 0x26000..0x44ff8 | 126,968 |
| unused (the `/bin` window must start on a 128 KB boundary for the MPU) | 0x44ff8..0x60000 | 110,600 |
| `/bin`: 37 programs, run in place | 0x60000..0xa0230 | 262,704 |
| `.data` initial values | 0xa0230..0xa0af0 | 2,240 |
| **spare below 0xAD000** | 0xa0af0..0xad000 | **50,448** |

Programs in `/bin` (bytes): hamsh 168,532; ptest 12,220; grep 10,180; vi
8,872; exportfs 8,284; sort 4,176; cut 3,928; ls 3,724; cp 3,412; kill
3,404; tr 3,272; idlestat 3,000; suspend 2,088; uniq 2,044; free 1,704;
help 1,624; wc 1,560; cat 1,388; mv 1,356; seq 1,240; tail 1,236; date
1,208; ps 1,196; sleep 1,096; keypress 1,080; head, df 984; tee 968;
setdate 952; touch 904; od 888; mkdir 856; rm 840; hello 728; echo 712;
halt, regprobe 568. **Left out:** `p9srv_demo` (10 KB; `exportfs` is the 9P
server here), `srv` (no second serial port as a file on this board), `crel`
(cannot be an RWPI program). Everything else fits, `vi` included. If room
is needed again: `ptest` (a test program) and `vi` are the largest after
the shell; moving `/bin` down to 0x40000 would need the kernel under
104 KB.

**RAM.** Kernel heap 48,064 bytes (was 49,408: the connection, `/srv`,
device and channel tables are static data), 7,440 in use at boot, 42,032
at the test session's peak. Each mounted 9P server takes a 1,048-byte
message buffer from it; `exportfs` runs in a 12 KB block of the program
arena. Beside the shell and a running `exportfs` there is room for the
small programs (`cat`, `ls`, `echo`, `wc`, `seq`, `ps`), not for `grep`,
`cp`, `sort` or `vi`. Stacks in the Renode session: init 1,648 of 3,072;
hamsh user 1,672 of 8,192, kernel 1,872 of 4,096; the largest kernel stack
of any process 1,904; largest user stack 7,140 of 8,192 (grep).

**Pins.** `/dev/gpio/red`, `blue`, `button` and the header pins by nRF
number are the GPIO registers ([`../devices.md`](../devices.md), "The
Feather's pins"):

```
hamsh$ echo 1 > /dev/gpio/blue     # blue LED on
hamsh$ echo 0 > /dev/gpio/blue
hamsh$ echo 1 > /dev/gpio/red      # red LED: stops blinking and stays on
hamsh$ cat /dev/gpio/button        # 1; 0 while the user switch is held
```

To check on the board: that the LEDs follow (both are active high per
Adafruit's `LED_STATE_ON 1`), that `button` reads 0 when pressed, and a
header pin with a meter.

**Namespaces and 9P at the prompt** ([`../namespaces.md`](../namespaces.md),
"On the Feather nRF52840"; [`../9p.md`](../9p.md)):

```
hamsh$ cat /proc/self/ns
hamsh$ ns { bind -b /tmp/mybin /bin ; seq 3 }
hamsh$ mkdir /tmp/ex ; echo one > /tmp/ex/a
hamsh$ exportfs -s ex /tmp/ex &
hamsh$ mount /srv/ex /n/ex ; cat /n/ex/a
hamsh$ unmount /n/ex ; rm /srv/ex
```

and from the PC, with nothing else on the serial port:

```
$ tools/hm9p.py --tty /dev/ttyUSB0 ls /dev -- cat /proc/version -- write /dev/gpio/blue 1
```

The last is the least certain on real hardware: 9P requests of up to 280
bytes arrive in one burst at 115200 baud and the UARTE takes them a byte
per interrupt; Renode shows the protocol working on this image (16 checks,
`tests/nrf52/renode_9p.sh`), not the timing. If it fails on the board the
tool reports a timeout and the console may be left in wire mode: reset the
board. Add to the bring-up checklist: `help`; the LED commands above;
`cat /proc/self/ns`; the `ns { }` line; the `exportfs`/`mount` lines; then
`hm9p.py ... cat /proc/version` from the PC.

## 8. How this board is put together

| Path | What |
|--|--|
| `boards/feather_nrf52840/` | `vectors.S` (64-entry table), `link.ld` (memory map above), `board.ad` (console, LED, tick, MPU window, memory report), `board.mk` (CPU, soft double, RWPI, stacks, UF2), `patches/` (size patches) |
| `soc/nrf52/` | UARTE, GPIO, RTC tick, delays: IP shared by the nRF52 family |
| `soc/nrf52840/soc.ad` | addresses, IRQs, clock start, FICR, reset reason, APPROTECT |
| `scripts/mkuf2.py` | Intel HEX to UF2 |
| `tests/nrf52/` | the checks of section 6, the Renode platform, the session |
| `third_party/nordic-mdk-nrf52840/` | Nordic's device headers (BSD-3-Clause), read as data |
| `third_party/llvm-compiler-rt-builtins/` | soft double precision (Apache-2.0 WITH LLVM-exception) |

Differences from the Cortex-M7 boards, and why:

- **No double-precision FPU** (fpv4-sp-d16). float64 arithmetic calls
  compiler-rt's `__aeabi_d*`. The hard-float ABI and the Adder target are
  unchanged, since the M4F still has d0-d15 as register pairs.
- **8 MPU regions**, not 16: the kernel's plan uses 0..7 and the board adds
  none. Region rules are the same PMSAv7 ones (power-of-two size of at least 32
  bytes, aligned to its size, eight sub-regions from 256 bytes). The M4 has
  no cache and does not read speculatively, so no extra no-access regions
  are needed (the M7 Teensy needs them). Region 4 is, while a process
  runs, the read-only executable window over /bin.
- **The tick is RTC1**, because SysTick stops while the nRF52's CPU sleeps in WFI.
- **Programs are ROPI/RWPI** (`PROG_ABI=rwpi`): code runs in place from
  flash, r9 points at the data. See `docs/porting.md`.
