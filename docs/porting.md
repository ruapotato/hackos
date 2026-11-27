<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Porting HackOS to a new board

HackOS runs on three boards so far: QEMU `mps2-an500` (Cortex-M7, the test
machine), the Teensy 4.1 (i.MX RT1062, Cortex-M7) and the Adafruit
Feather nRF52840 (Cortex-M4F). This note says what a new one needs, in
the order to write it. The last two are UNTESTED ON HARDWARE; their docs
in `docs/boards/` say how each was checked without the board.

## 1. How a board is selected

`make BOARD=name` looks up `BOARD_DIR_name` in the Makefile and includes
`boards/<dir>/board.mk`. Adder has no include path, so
`scripts/mkroot.sh` builds `build/<BOARD>/root/`, a tree of links to the
sources in which `board` is `boards/<dir>`. Kernel code imports
`board.board`, and a board's size patches are applied to copies there.

A board directory holds five files:

| File | What |
|--|--|
| `board.mk` | `CPU`, `FPU`, `SOFT_DOUBLE`, `PROG_ABI`, `PROGS_SKIP`, `IMAGES`, `BOARD_ALL` (extra outputs: .hex, .uf2), `PROG_AFLAGS`, `BOARD_PATCHES`, `STACK_<prog>` / `STACK_DEFAULT_BOARD`, `LDFLAGS_BOARD` |
| `vectors.S` | `hackos_vectors` (16 + the chip's interrupt count, aligned to the power of two above its size) and whatever the boot path needs before it: Teensy the FlexSPI boot header, QEMU the reset-only table at 0. Included by `arch/armv7m/startup.S`. Optional `board_reset_early` (define `BOARD_RESET_EARLY`) for work before a stack exists |
| `link.ld` | The memory map, with the section and symbol names of `boards/mps2_an500/link.ld` (`__vectors_start`, `__text_end`, `__data_load/start/end`, `__xbss_*`, `__bss_*`, `__stack_top`, `__fault_stack_top`, `__heap_start/end`, `__prog_start/end`, `__user_start/end`, `__ramdisk_*`) |
| `board.ad` | The board functions below |
| `patches/` | Per-board size patches of copied or kernel code (`<path>.patch`, a `diff -u` against the committed file, with a header saying why) |

## 2. The board functions (`board.ad`)

| Function | Purpose |
|--|--|
| `board_name`, `board_cpu_hz` | banner, delays |
| `board_init_early()` | after `.data`/`.bss`, before the console: clear `.xbss` if the RAM is not zeroed at reset, watchdogs off, interrupts off, caches, a sign-of-life LED |
| `board_console_init`, `_putc`, `_rx_irq_enable`, `_rx_ready`, `_getc`, `_rx_irq_ack` | the UART. Transmit polled with a time limit; receive by interrupt into the line discipline (`drivers/tty/console.ad`, whose handler is `uart0_rx_handler`: put it at the UART's vector) |
| `board_tick_start(hz)` | start a periodic interrupt that calls `systick_handler()` `hz` times a second (SysTick on the M7 boards; RTC1 on the nRF52, because SysTick stops in WFI there) |
| `board_systick_csr`, `board_systick_reload` | SysTick settings (`kernel/systick.ad`, `board_tick_start` on SysTick boards) |
| `board_mpu_code_*`, `_kram_*`, `_xram_*` | MPU regions 0, 2 and 3: code (read-only), kernel RAM, large RAM; each a power of two aligned to itself |
| `board_mpu_extra()` | regions 8.. (only where the MPU has 16 regions) |
| `board_mpu_xip_rbar/rasr`, `board_xip_lo/hi` | the flash window programs run from in place, region 4 while a process runs; all 0 when programs are copied into RAM |
| `board_storage_init()` | register the block device `/sd` is mounted from, or -1 |
| `board_code_loaded(base, size)` | after code was written to RAM (I-cache invalidate on the M7) |
| `board_late_init()` | after `kernel_init`: the boot report (clocks, chip id), the heartbeat thread |
| `board_halt(code)` | last call before the reset: flush the UART; for a code other than 0, signal it and stop |

## 3. A new board on a chip family HackOS knows

Example: another i.MX RT1062 board, or another nRF52840 board.

1. Copy the closest `boards/<dir>/` and add `BOARD_DIR_<name>` to the Makefile.
2. **Memory map** (`link.ld`): where the boot ROM or bootloader starts the
   image and what it must not overwrite; RAM regions; where the kernel
   heap and the program arena go. The arena's blocks are k/8 of
   power-of-two regions aligned to their size, so place `__prog_start` so
   that the biggest program (the shell) gets its boundary.
3. **Pins**: console TX/RX, LED. Use the vendor's pin table or variant
   file, and record the extracted facts as the Teensy and Feather checks do
   (`tests/imxrt/teensy41_pins.txt`, `tests/nrf52/feather_facts.txt`).
4. **Clocks**: start what the console's baud rate needs. Report what you
   found instead of assuming.
5. **Sizes**: `make BOARD=x`, then `llvm-size` on the kernel and on
   `build/x/user/*.elf`. Where they do not fit, add size patches (section 6).
6. **Image format**: the boot header or the bootloader's file format
   (.hex for the Teensy loader, .uf2 for Adafruit's bootloader, via
   `scripts/mkuf2.py`).
7. **Checks** under `tests/<family>/`, wired into a `make test-<family>`:
   register constants against the vendor header (`tests/nrf52/check_regs.py`,
   `tests/imxrt/check_regs.py`), pins, the image against the boot rules,
   and the image itself in an emulator if one models the chip (Renode has
   many: `platforms/cpus/`), else the drivers against register models
   (`tests/imxrt/drvtest.sh`).

## 4. A new chip family on ARMv7-M (Cortex-M3/M4/M7)

1. **`soc/<family>/`**: drivers for the IP blocks (UART, GPIO, timer), each
   function taking the instance's base address; and `soc/<chip>/soc.ad`:
   addresses, IRQ numbers, clock start, watchdog, chip identity. Tag every
   upper-case constant `# hdr: <vendor header symbol>` or
   `# unchecked: <why>` so a checker can compare it.
2. **CPU and FPU** in `board.mk`. The Adder target is
   `thumbv7em-none-eabihf` for both the M7 and the M4F; only clang's
   `-mcpu`/`-mfpu` change. The `.S` files pick `.cpu`/`.fpu` by
   `HACKOS_CPU_M4`. A third CPU there needs one more `#ifdef`.
3. **No double-precision FPU** (M4F: fpv4-sp-d16): `SOFT_DOUBLE := 1`
   links compiler-rt's `__aeabi_d*` into the kernel and every program. The
   hard-float calling convention stays: doubles are still passed in d0-d7,
   which exist as register pairs. Check that no `v*.f64` arithmetic is
   left (`tests/nrf52/run_all.sh`, code step).
4. **MPU**: count the regions (`MPU_TYPE.DREGION`). The kernel's plan uses
   0..7, so an 8-region MPU (M3/M4, some M7) leaves nothing for
   `board_mpu_extra`. The PMSAv7 rules are the same on M3/M4/M7. On an M7 with
   caches, cover unanswered address ranges with no-access regions (it reads
   speculatively). The M3/M4 do not need that.
5. **Little RAM** (under ~512 KB): `PROG_ABI := rwpi` (section 5) and size
   patches.

## 5. Programs: PIE or RWPI

`PROG_ABI=pie` (default): a program is a position-independent executable
whose code and data move together. The loader copies all of it into the
process's block and applies `R_ARM_RELATIVE` relocations. Simple, but every
program's code sits in RAM: the shell's 200 KB of code alone is more than
an nRF52840 can spare.

`PROG_ABI=rwpi` (the Feather): programs are compiled `-fropi -frwpi`. Code
and constants reach each other PC-relative; writable data is reached
relative to **r9**, the static base. `user/rt/prog_rwpi.ld` links code at 0
and data at the marker address 0x40000000 (an `ET_EXEC` with two
`PT_LOAD`s). The loader (`kernel/proc.ad`, `_load_rwpi`):

- if the file is in the ROM table and its code lies inside the board's
  flash window (`board_xip_lo/hi`, 8-byte aligned), runs the code **in
  place**; otherwise copies it into the block above the data;
- copies the data segment's initial values, clears bss, heap and stack;
- starts the program with r9 = the data's address: in the first context
  frame for `spawn`, and through `Thread.exec_sb`, which `syscall_trampoline`
  loads into r9 on the way out, for `exec`.

The kernel itself is built without RWPI. It treats r9 as an ordinary
callee-saved register and so preserves a program's r9 across every call
and interrupt. An RWPI program cannot have absolute pointers in
initialised data (they would need a relocation); the build check refuses
them. The C test program `crel` is skipped for that reason.
`board_mpu_xip_*` opens the flash window to processes read-only and
executable (MPU region 4), and `uok` lets a process pass pointers into it
(string constants live there).

## 6. Size knobs

Static arrays are real memory from boot, so sizes are compile-time
constants changed by per-board patches (`boards/<dir>/patches/`, applied
by `mkroot.sh` in the board's build tree only). The ones that matter, with
the Feather's values:

| File | Knob | QEMU / Teensy / Feather |
|--|--|--|
| `kernel/sched/core.ad` | threads, kernel stack per process, reaper stack | 32 / 32 / 16; 16 / 16 / 4 KB; 8 / 8 / 3 KB |
| `kernel/proc.ad` | exec argument buffer | 4 / 4 / 1 KB |
| `kernel/pipe.ad` | pipe buffer | 4 / 4 / 1 KB |
| `fs/tmpfs.ad`, `mm/page_alloc.ad` | files in /, chunk size | 1024 / 128 / 32; 4 / 4 / 1 KB |
| `fs/hvfs.ad` | directory listing snapshot | 8 / 8 / 2 KB |
| `init/main.ad` | init thread stack | 16 / 16 / 3 KB |
| `user/hamnix/hamsh.ad` | the shell's arenas and buffers | 1.5 MB / 218 KB / 104 KB of data |
| `lib/regex.ad`, `user/hamnix/grep.ad`, `ls.ad`, `lib/passwd/passwd.ad` | grep's tables, ls's listing, the passwd table | see the patches |
| `board.mk` | `STACK_<prog>`, `STACK_DEFAULT_BOARD` | 64 / 32 / 8 KB for the shell |

Measure, do not guess. The Feather's board prints a memory report at
`halt` (kernel heap peak, failed allocations and the size of the last one,
the program arena's peak, the largest kernel and user stack any process
used: `proc_ustack_used`, `reap_kstack_max`). `tests/nrf52/renode_session.sh` quotes it.

## 7. A new architecture: Cortex-M0+ (RP2040) or Cortex-M33 (RP2350)

The arch layer is `arch/armv7m/` (five assembly files: start-up, context
switch and system-call entry, special registers, EABI shims, the user's
`svc` stub) and the compiler target `thumbv7em-none-eabihf`.

**Cortex-M33 (RP2350, ARMv8-M Mainline).** Closest to what exists:
- Compiler: an Adder target `thumbv8m.main-none-eabihf` (clang
  `-mcpu=cortex-m33 -mfpu=fpv5-sp-d16`). The instruction set is a superset
  of ARMv7E-M's, so the LLVM lane should need only the triple. The RP2350's
  FPU is single precision: `SOFT_DOUBLE := 1` (the RP2350 also has a
  double-precision coprocessor, DCP, that a later port could use).
- **MPU: PMSAv8**, different from PMSAv7. Regions are base/limit pairs
  (RBAR/RLAR) with 32-byte granularity: no power-of-two sizes, no
  sub-regions, no overlap allowed. Attributes go through MAIR. `kernel/mpu.ad`
  needs a second implementation: the plan is simpler, as a process block
  can be any 32-byte-aligned size, so `_region_for` and `parena`'s
  power-of-two alignment go away. Overlapping regions are not allowed, so
  the "region 1 null guard over region 0" layering must become disjoint
  regions.
- TrustZone: run everything Secure, or set up SAU/IDAU. The simplest port
  stays Secure and ignores it.
- Stack limit registers (PSPLIM/MSPLIM) can replace the stack-guard regions 6 and 7.
- RP2350 boot: an IMAGE_DEF block in the first 4 KB of flash for the boot
  ROM, XIP flash at 0x10000000, 520 KB SRAM. UF2 family 0xE48BFF59
  (ARM-S). Programs as RWPI running from XIP flash, as on the nRF52.

**Cortex-M0+ (RP2040, ARMv6-M).** The biggest change:
- Compiler: target `thumbv6m-none-eabi` (`-mcpu=cortex-m0plus`), **no
  FPU**, soft float for float32 and float64 (compiler-rt has both), and
  the soft-float calling convention. Adder's lane must emit IR that the
  Thumb-1 back end accepts. LLVM handles the instruction selection, but
  check atomics: ARMv6-M has no LDREX/STREX, so anything lowered to them
  must become interrupt-masked sequences.
- `arch/armv6m/` instead of `arch/armv7m/`: no `BASEPRI` (the kernel masks
  with BASEPRI 0x40 in `switch.S` and `cpu_irq_save`; use PRIMASK), no
  `stmdb`/`ldmia` with high registers (save r8-r11 through r4-r7), no
  `it` blocks, no `cbz` beyond the encodable range, no FP context. The
  PendSV/SVC design carries over. `hackos_fault_entry` changes (no
  CFSR/MMFAR: the M0+ reports only HardFault).
- MPU: the RP2040's M0+ has the optional **8-region PMSAv6** MPU, close to
  PMSAv7 (power-of-two regions, sub-regions from 256 bytes). `kernel/mpu.ad`
  works as is apart from the attribute bits.
- No 64-bit multiply instruction: more `__aeabi_lmul` calls, and
  `rt.ad`'s divides get slower.
- RP2040 boot: a 256-byte boot2 stage at the start of flash for the QSPI
  chip, XIP at 0x10000000, 264 KB SRAM. UF2 family 0xE48BFF56. Programs
  RWPI from XIP flash. Two cores: run on core 0 only.

Both RP chips have a ROM UF2 bootloader. `scripts/mkuf2.py --family` works
for them as it is.
