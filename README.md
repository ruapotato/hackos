<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# HackOS

A small operating system for the HackerSlide hack pad: a handheld built around
an NXP i.MX RT117x microcontroller (ARM Cortex-M7, double-precision FPU, memory
protection unit but no MMU, 64-128 MB of SDRAM). HackOS is written in
[Adder](https://github.com/HamnixOS/adder), the language of the Hamnix operating
system (it needs the `cortex-m7` branch of
[ruapotato/adder](https://github.com/ruapotato/adder/tree/cortex-m7)), and is meant to reuse Hamnix's file-system layer, libraries and shell
on top of a new kernel that needs no page tables.

## Status: milestone 1, emulator only

**This is not an operating system yet.** What exists is the foundation under
one: the Adder compiler targeting Cortex-M7, a start-up runtime, and a
self-test that runs in QEMU's `mps2-an500` machine (an ARM development board
model with a Cortex-M7). Nothing here has run on real hardware, and QEMU does
not model the i.MX RT1170, so no HackerSlide peripheral is touched.

Works, and is checked by `make test`:

- Adder compiled to Thumb-2 with the hard-float ABI, linked with `ld.lld`
- vector table, reset, `.data`/`.bss` set-up, FPU enable, VTOR
- console output on the board's UART
- a SysTick interrupt handler and an SVCall handler written in Adder
- double-precision arithmetic on the FPU, 64-bit integer multiply, divide and
  modulo, structs with pointers
- memory-mapped register access through `volatile` pointers
- fault handlers that print the fault status registers and the stacked frame
- the run-time helpers the compiler's output needs (64-bit divide, 64-bit
  integer to and from float64, memcpy/memset), written in Adder
- ending an emulator run with a pass/fail exit status (ARM semihosting)

Does not exist yet: threads, a scheduler, system calls, memory protection, a
heap, a file system, drivers for anything but the emulated UART, the shell,
any i.MX RT support, and any way to load a program.

Known shortcomings of what does exist are listed at the end.

## Build and test

Requirements: `clang` and `ld.lld` (19 is what was used), `llvm-objdump`,
`llvm-objcopy`, `llvm-nm`, `llvm-size`, `qemu-system-arm` (10.0 was used),
Python 3.10+ and GNU make. No ARM GCC, no newlib, no compiler-rt.

HackOS needs the Adder compiler with the `thumbv7em-none-eabihf` target
(branch `cortex-m7` of the Adder fork). The two trees are separate; point
`ADDER` at a checkout:

```sh
make test ADDER=/path/to/adder      # default: ../adder
```

`make test` bootstraps the compiler in its own tree if needed, builds
everything here from source, and runs:

1. the compiler's own regression test for this target
   (`$ADDER/scripts/test_llvm_thumbv7em.sh`: emitted IR and disassembly);
2. static checks on the linked image (vector table, no undefined symbols,
   FPU instructions present, `volatile` accesses present in the IR);
3. the self-test image in QEMU: every check prints `PASS` or `FAIL`, and the
   number of failures is the exit status;
4. a second image that executes an undefined instruction on purpose, to check
   that the fault handler reports it.

It exits non-zero if anything fails. Other targets: `make run` (self-test with
the UART on your terminal), `make size`, `make measure` (code size of small
functions against the same functions in C).

## Layout

| Path | What |
|--|--|
| `arch/armv7m/startup.S` | vector table, reset stub, fault entry, and shims from the EABI helper names to their Adder implementations. The only assembly. |
| `boards/mps2_an500/` | linker script and board constants for the QEMU machine |
| `kernel/start.ad` | `.data`/`.bss`, VTOR, fault enables, console, calls `main` |
| `kernel/rt.ad` | 64-bit divide/modulo, integer/float64 conversion, memcpy/memmove/memset |
| `kernel/cpu.ad` | interrupt masking, `wfi`, special registers, MMIO access |
| `kernel/fault.ad` | fault report |
| `kernel/systick.ad` | system timer and its interrupt handler |
| `kernel/print.ad` | console formatting |
| `kernel/semihost.ad`, `kernel/exit.ad` | ending an emulator run |
| `demo/main.ad` | the self-test |
| `tests/` | test runner, fault-test image, measurement fixtures |

There is no C in the firmware. `tests/measure/cost.c` is a measurement
yardstick compiled on its own and never linked into an image.

How Adder code and assembly call each other on this target is documented in
the compiler tree, `docs/cortex_m7.md`.

## Known shortcomings

- Emulator only; the memory map, UART and clock are those of `mps2-an500`.
- `kernel/semihost.ad` ends the run with a `bkpt` instruction. On real
  hardware without a debugger that is a fault; it must be replaced before the
  first board bring-up.
- `asm_volatile` cannot take operands, so special registers are read through
  a scratch global. Not re-entrant: an interrupt handler that calls
  `cpu_ipsr()` while thread code is inside `cpu_primask()` could corrupt the
  thread's result. Harmless today (the handlers that do this exist only in the
  self-test), wrong for a kernel.
- 64-bit division is a bit-at-a-time loop: correct, slow.
- Division by zero in 64-bit arithmetic returns 0 instead of trapping.
- String literals are placed in `.data` (RAM, with a copy in the image), not
  in read-only memory: the compiler emits them as writable globals.
- The console driver polls; there is no input.
- Board support is selected by import path, not by a build option.

## Licence

AGPL-3.0-or-later. See `LICENSE`.
