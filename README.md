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

## Status: milestone 2, emulator only

**A kernel core, not yet a usable system.** HackOS now schedules threads,
takes system calls, protects memory and serves files from RAM, and has a
console you can type at. All of it runs in QEMU's `mps2-an500` machine (an ARM
development board model with a Cortex-M7). Nothing here has run on real
hardware; QEMU does not model the i.MX RT1170, so no HackerSlide peripheral is
touched. There is no way to load a program yet: "user" code is compiled into
the same image and runs unprivileged.

Works, and is checked by `make test`:

- **Threads.** Preemptive scheduler, eight fixed priorities, round robin with
  1 ms ticks and 10 ms slices; create, exit, join, sleep, yield; an idle
  thread. Threads run on the process stack, interrupt handlers on the main
  stack; the context switch is PendSV and saves the floating-point registers
  only for threads that use them.
- **Synchronisation.** Critical sections that mask by priority (BASEPRI), a
  mutex with simple priority inheritance, semaphore, condition variable,
  message queue, wait queues with timeouts.
- **System calls** through `svc`, from unprivileged threads, numbered like
  Hamnix's native interface where the calls match: files, directories,
  threads, sleep, anonymous memory. See [`docs/syscalls.md`](docs/syscalls.md).
- **Memory protection.** Kernel data, the kernel heap and peripherals are out
  of reach of unprivileged threads; code and constants are read-only for
  everyone; the first 4 KB fault (null pointers); every thread stack ends in a
  1 KB guard. A fault ends the thread that caused it, with a report naming
  it, and the system carries on.
- **Heap.** First fit with coalescing, statistics, a consistency check.
- **Files.** Hamnix's RAM file system (`fs/tmpfs.ad`) and mount table,
  unmodified, under a small HackOS descriptor layer; `/dev/console`,
  `/dev/null`, `/dev/zero`.
- **Console.** Interrupt-driven UART input, line editing, and a built-in
  monitor (`ps`, `heap`, `ls`, `cat`, `write`, `fault ...`).
- **C code.** A vendor sensor driver (Sensirion SHT4x, C, unmodified) is linked
  in and called directly from Adder; its platform layer is Adder code that the
  C driver calls. A link-time check keeps the two calling conventions apart.
- Everything from milestone 1: start-up, FPU, 64-bit arithmetic helpers,
  fault reports, ending an emulator run with a status.

Does not exist yet: loading programs, processes, `exec`, pipes, the Hamnix
shell, FAT or any block device, any real device driver, any i.MX RT support.

Known shortcomings are listed at the end.

## Build and test

Requirements: `clang` and `ld.lld` (19 is what was used), `llvm-objdump`,
`llvm-objcopy`, `llvm-nm`, `llvm-size`, `qemu-system-arm` (10.0 was used),
Python 3.10+ and GNU make. No ARM GCC, no newlib, no compiler-rt.

HackOS needs the Adder compiler with the `thumbv7em-none-eabihf` target
(branch `cortex-m7` of the Adder fork). The two trees are separate; point
`ADDER` at a checkout:

```sh
make test ADDER=/path/to/adder      # default: ../adder
make run                            # the monitor on your terminal (Ctrl-A X leaves QEMU)
```

`make test` bootstraps the compiler in its own tree if needed, builds
everything here from source, and runs:

1. the compiler's regression test for this target;
2. checks that the files copied from Hamnix and the third-party C code are
   byte-identical to their recorded originals, and that C and Adder code only
   call each other through `extern "C"` declarations;
3. static checks on the linked images (vector tables, the empty null-guard
   area, constants in read-only memory, no undefined symbols);
4. the run-time self-test from milestone 1 (arithmetic, FPU, start-up);
5. the kernel tests: one image, about a hundred counted checks, with console
   input typed into the emulated UART by the harness;
6. a scripted session with the monitor;
7. an image that faults before the scheduler starts, for the fatal report.

Every check prints `PASS` or `FAIL`; the number of `PASS` lines must equal the
number of checks in the source, so a check that does not run is a failure.
The kernel tests use QEMU's instruction counter as the clock, which makes the
tick-exact timing checks independent of the host's load; the monitor session
runs in real time.

Other targets: `make size`, `make measure` (code size of small functions
against the same functions in C).

## Layout

| Path | What |
|--|--|
| `arch/armv7m/startup.S` | vector tables, reset stub, fault entry, shims from the EABI helper names to their Adder implementations |
| `arch/armv7m/switch.S` | PendSV context switch, SVC entry and exit, first-thread start |
| `arch/armv7m/cpu.S` | special-register access as leaf routines |
| `boards/mps2_an500/` | linker script and board constants for the QEMU machine |
| `kernel/sched/core.ad` | threads, scheduler, wait queues, timer queue |
| `kernel/sync.ad` | mutex, semaphore, condition variable, message queue |
| `kernel/syscall.ad`, `user/sys.ad` | system-call dispatch; the user-side wrappers |
| `kernel/mpu.ad`, `kernel/trap.ad` | memory protection plan; faults that end a thread |
| `kernel/start.ad`, `kernel/init.ad` | start-up, kernel bring-up |
| `kernel/rt.ad` | 64-bit divide/modulo, integer/float64 conversion, memcpy/memset |
| `kernel/fault.ad`, `kernel/print.ad`, `kernel/printk/` | fatal report, console formatting |
| `mm/` | heap (`heap.ad`) and the allocation names Hamnix code expects |
| `fs/hvfs.ad` | descriptors, paths, mounts, device files (HackOS) |
| `fs/tmpfs.ad`, `fs/vfs_mount.ad`, `lib/p9dir.ad`, `lib/9p/` | copied from Hamnix, unmodified (`fs/HAMNIX_ORIGIN`) |
| `drivers/tty/console.ad` | UART console with line discipline |
| `drivers/i2c/` | software I2C bus, Sensirion platform layer and driver declarations |
| `init/` | the interactive image: kernel plus monitor |
| `third_party/` | vendor C code with licences and upstream records |
| `lib/cshim/` | the few C library functions C code may use |
| `demo/main.ad` | the milestone-1 run-time self-test |
| `tests/` | kernel test image, harness, link-rule check, measurement fixtures |
| `docs/syscalls.md` | the system-call table and how it differs from Hamnix |

Assembly is three files (about 700 lines): what the processor requires at
exception entry and exit, register access, and the calling-convention shims.
The kernel is Adder. The only C is third-party driver code, its small library
shim and test fixtures.

How Adder code, assembly and C call each other on this target is documented in
the compiler tree, `docs/cortex_m7.md`.

## Known shortcomings

- Emulator only; the memory map, UART and clock are those of `mps2-an500`.
  Tables are sized for its 16 MB (the target has 64 MB).
- `kernel/semihost.ad` ends a run with a `bkpt` instruction. On real hardware
  without a debugger that is a fault; it must go before the first board
  bring-up.
- Unprivileged threads are protected from the kernel, not from each other:
  they share one memory arena and may execute any code in the image. Isolation
  between programs needs program loading.
- A thread that faults while it holds a kernel lock (inside a system call)
  leaves the lock held.
- A stack frame larger than the 1 KB guard can step over it.
- The heap, the console output path and the file system each run with kernel
  interrupts masked or under one big lock for longer than a real-time system
  should. Console output is polled.
- Every non-empty tmpfs file costs at least 128 KB of kernel heap (Hamnix's
  chunk sizes, unchanged), and removing an open file is refused.
- No way to end or signal another thread; no thread-local storage.
- 64-bit division is a bit-at-a-time loop: correct, slow.
- Board support is selected by import path, not by a build option.

## Licence

AGPL-3.0-or-later. See `LICENSE`.
