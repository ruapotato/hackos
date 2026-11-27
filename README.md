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

## Status: milestone 3, emulator only

**A shell prompt that runs real programs, in the emulator.** HackOS boots to
Hamnix's shell, `hamsh`, on the serial console. The shell is an unprivileged
process loaded from a file; so are `ls`, `cat`, `grep` and the other programs
it runs. Pipelines, redirections and shell scripts work. All of it runs in
QEMU's `mps2-an500` machine (an ARM development board model with a
Cortex-M7). Nothing here has run on real hardware; QEMU does not model the
i.MX RT1170, so no HackerSlide peripheral is touched.

```
hamsh$ ls /bin | grep h | wc
5 5 27
hamsh$ echo second line >> /tmp/note
hamsh$ cat /sd/README.TXT
```

Works, and is checked by `make test`:

- **Ctrl-C** ends the foreground program, whether it loops in its own code
  or waits inside the kernel.
- **Processes without an MMU.** A program is a position-independent ELF
  executable. The loader copies it from the file system into one block of
  memory (stack at the bottom, code and data above), applies its relocations,
  and the memory protection unit opens exactly that block to it. A process
  cannot read or write the kernel, another process, or even the kernel's
  code. `spawn(path, argv)` starts a program; `exec`, `exit`, `waitpid` are
  there; `rfork` is implemented as vfork (the child borrows the parent's
  memory until it execs) because that is what Hamnix's shell calls. A process
  that faults is ended with a one-line report; its memory, files and pipe
  ends are released, and a kernel lock it held is taken back.
- **Pipes and `/fd` names**, the one part of Hamnix's namespace model its
  shell cannot do without: `/fd/0`.. are names bound per process to the
  console, a pipe end or a file.
- **Hamnix's shell and nine of its programs**, copied from Hamnix: `echo cat
  ls cp rm mkdir wc head grep` under `/bin`, which is a read-only table of
  files inside the kernel image, read in place. The shell's source differs
  from Hamnix's by a patch of 41 lines that makes its static tables smaller.
- **Files.** Hamnix's RAM file system at `/` (now 8 KiB for a small file
  instead of 128 KiB), devices at `/dev`, and Hamnix's FAT32 code at `/sd`
  over a RAM disk that the emulator preloads with an image: read, create,
  append, overwrite, remove, run programs from it.
- **Threads, synchronisation, system calls, memory protection, heap,
  console, C code in the image**: the kernel core of milestone 2, unchanged
  in behaviour. System calls are numbered like Hamnix's native interface
  where the calls match; see [`docs/syscalls.md`](docs/syscalls.md).
- Runs end with a status line and a system reset; nothing depends on a
  debugger channel (semihosting is gone).

Does not exist yet: any real device driver, any i.MX RT support, signals
other than Ctrl-C ending the foreground program, threads inside a process,
shared libraries, a way to compile on the device.

Known shortcomings are listed at the end.

## Build and test

Requirements: `clang` and `ld.lld` (19 is what was used), `llvm-objdump`,
`llvm-objcopy`, `llvm-nm`, `llvm-size`, `llvm-strip`, `qemu-system-arm` (10.0
was used), Python 3.10+, GNU make, `patch`, and mtools (`mformat`, `mcopy`,
`mmd`) for the FAT image. No ARM GCC, no newlib, no compiler-rt.

HackOS needs the Adder compiler with the `thumbv7em-none-eabihf` target
(branch `cortex-m7` of the Adder fork). The two trees are separate; point
`ADDER` at a checkout:

```sh
make test ADDER=/path/to/adder      # default: ../adder
make run                            # the shell on your terminal (Ctrl-A X leaves QEMU;
                                    # `halt` at the prompt ends the run)
```

`make test` bootstraps the compiler in its own tree if needed, builds
everything here from source, and runs:

1. the compiler's regression test for this target;
2. checks that the files copied from Hamnix are byte-identical to their
   recorded originals, or differ by exactly the patch file next to them, that
   the third-party C code is unmodified, and that C and Adder code only call
   each other through `extern "C"` declarations;
3. static checks on the linked images (vector tables, the empty null-guard
   area, constants in read-only memory, no undefined symbols);
4. the run-time self-test from milestone 1 (arithmetic, FPU, start-up);
5. the kernel tests: one image, 163 counted checks, including processes
   (isolation, faults, spawn, rfork, exec, wait), pipes and FAT, with console
   input typed into the emulated UART by the harness;
6. a scripted session with the kernel monitor (`build/monitor.elf`);
7. an image that faults before the scheduler starts, for the fatal report;
8. a scripted session with the shell: pipelines, redirections, a faulting
   program, the FAT volume, and a script file run by a second shell.

Every check prints `PASS` or `FAIL`; the number of `PASS` lines must equal the
number of checks in the source, so a check that does not run is a failure.
The kernel tests use QEMU's instruction counter as the clock, which makes the
tick-exact timing checks independent of the host's load; the two typed
sessions run in real time.

Other targets: `make size`, `make measure` (code size of small functions
against the same functions in C; sizes of the image and of every program).

## Layout

| Path | What |
|--|--|
| `arch/armv7m/startup.S` | vector tables, reset stub, fault entry |
| `arch/armv7m/switch.S` | PendSV context switch, SVC entry and exit, first-thread start |
| `arch/armv7m/cpu.S`, `aeabi.S` | special-register access; shims from the EABI helper names to their Adder implementations (also linked into every program) |
| `boards/mps2_an500/` | linker script and board constants for the QEMU machine |
| `kernel/sched/core.ad` | threads, scheduler, wait queues, timer queue, the reaper |
| `kernel/proc.ad` | processes: program loader, spawn, exec, rfork, wait |
| `kernel/pipe.ad` | pipes |
| `kernel/sync.ad` | mutex, semaphore, condition variable, message queue |
| `kernel/syscall.ad`, `kernel/uaccess.ad` | system-call dispatch; checks of caller addresses |
| `kernel/mpu.ad`, `kernel/trap.ad` | memory protection plan; faults that end a thread or process |
| `kernel/block/blk.ad` | block devices (a RAM disk so far) |
| `kernel/start.ad`, `kernel/init.ad`, `kernel/exit.ad` | start-up, kernel bring-up, ending a run |
| `kernel/rt.ad` | 64-bit divide/modulo, integer/float64 conversion, memcpy/memset |
| `kernel/fault.ad`, `kernel/print.ad`, `kernel/printk/` | fatal report, console formatting |
| `mm/` | heap (`heap.ad`) and the allocation names Hamnix code expects |
| `fs/hvfs.ad` | descriptors, paths, mounts, device files, `/bin`, `/fd` names, the FAT glue (HackOS) |
| `fs/tmpfs.ad`, `fs/fat.ad`, `fs/vfs_mount.ad`, `lib/p9dir.ad`, `lib/9p/` | copied from Hamnix (`fs/HAMNIX_ORIGIN`); `tmpfs.ad` with a size patch |
| `user/hamnix/` | Hamnix's shell and programs, copied; `hamsh.ad` with a size patch |
| `lib/p9.ad`, `perror.ad`, `regex.ad`, `hamcomplete.ad`, `passwd/` | Hamnix libraries those programs import, copied |
| `lib/hamui.ad`, `lib/hamsdl*.ad` | HackOS stand-ins for Hamnix's GUI libraries (the shell imports them) |
| `user/rt/` | what every program is linked with: entry point, system-call wrappers, heap, linker script |
| `user/progs/` | HackOS's own programs: `hello`, `halt`, the process test program, a C program |
| `user/sys.ad`, `user/faults.ad` | unprivileged code that is part of the kernel test image |
| `drivers/tty/console.ad` | UART console with line discipline |
| `drivers/i2c/` | software I2C bus, Sensirion platform layer and driver declarations |
| `init/main.ad`, `init/monitor*.ad` | the system image (init + shell); the kernel monitor image |
| `scripts/mkromfs.sh` | generates the table of ROM files |
| `third_party/` | vendor C code with licences and upstream records |
| `lib/cshim/` | the few C library functions C code may use |
| `demo/main.ad` | the milestone-1 run-time self-test |
| `tests/` | kernel test image, harness, link-rule check, measurement fixtures, the FAT image's contents |
| `docs/syscalls.md` | the system-call table and how it differs from Hamnix |

Assembly is five files (about 740 lines): what the processor requires at
exception entry and exit, register access, the calling-convention shims, and
the two-instruction system-call stub of user programs. The kernel is Adder.
The only C is third-party driver code, its small library shim and test
fixtures.

How Adder code, assembly and C call each other on this target is documented in
the compiler tree, `docs/cortex_m7.md`.

## Writing a program

```python
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    sys_write(1, "hello\n", 6)
    return 0
```

Put it in `user/progs/NAME.ad`, add `NAME` to `PROGS_OWN` in the Makefile, and
it appears as `/bin/NAME`. `STACK_NAME` (default 8192) and `HEAP_NAME`
(default 0) set its stack and heap; both are fixed when the program is
linked. A C file works the same way (`user/progs/crel.c`).

## Known shortcomings

- Emulator only; the memory map, UART and clock are those of `mps2-an500`.
  Tables are sized for its 16 MB (the target has 64 MB).
- **No signals, one exception.** Ctrl-C ends the process group the shell
  has named as the foreground one (`tcsetpgrp`), with status 130. Hamnix's
  shell names a group for a single foreground command, not for a pipeline:
  a pipeline that hangs cannot be stopped. There is no `kill`, no Ctrl-Z,
  and no end-of-file key while the console is in raw mode: `wc` typed without
  a redirection waits until Ctrl-C.
- **`rfork` is vfork.** A built-in command inside a pipeline, a `{ }` block
  after `&`, and everything else where Hamnix's shell forks and keeps running
  shell code works only as far as vfork allows: the child runs in the shell's
  own memory while the shell waits, changes it makes to shell variables stay,
  and it cannot write more than a pipe holds (4 KiB) to a stage that has not
  been started yet. `bind`, `mount`, `ns`, `enter` and services report that
  there are no namespaces.
- A process block is readable, writable and executable throughout: a program
  can overwrite its own code. Its size is fixed at start; there is no way to
  grow a heap.
- Registers are not cleared when a program starts: a new process can see
  floating-point register values left by whatever ran before it.
- A process is one thread. 32 threads and processes in all, 16 descriptors
  and 16 `/fd` names each, 16 pipes.
- The shell is large: a 400 KB file and a 2 MB block per running instance.
- FAT: FAT32 only, new names 8.3 only, no `mkdir`, no rename, no redirection
  to a file on it, one volume.
- A thread that faults while it holds a kernel lock no longer blocks the
  system, but what the lock protected may be half-updated.
- A kernel-stack frame larger than the 1 KB guard can step over it.
- The heap, the console output path and the file system each run with kernel
  interrupts masked or under one big lock for longer than a real-time system
  should. Console output is polled.
- Removing an open file is refused; directory reads are a snapshot.
- 64-bit division is a bit-at-a-time loop: correct, slow.
- Board support is selected by import path, not by a build option.

## Licence

AGPL-3.0-or-later. See `LICENSE`.

Files copied from Hamnix (`fs/HAMNIX_ORIGIN`: the file systems, the shell, the
programs and their libraries) are GPL-3.0-or-later by the same author. `third_party/` holds code under its own licences (currently
BSD-3-Clause), each with its licence file and an `UPSTREAM` record.
