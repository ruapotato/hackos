<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Hamnix Micro

A small operating system for the HackerSlide hack pad: a handheld built around
an NXP i.MX RT117x microcontroller (ARM Cortex-M7, double-precision FPU, memory
protection unit but no MMU, 64-128 MB of SDRAM). Hamnix Micro is written in
[Adder](https://github.com/HamnixOS/adder), the language of the Hamnix operating
system (it needs the `cortex-m7` branch of
[ruapotato/adder](https://github.com/ruapotato/adder/tree/cortex-m7)), and is meant to reuse Hamnix's file-system layer, libraries and shell
on top of a new kernel that needs no page tables.

## Status: milestone 5, emulators only

**A shell prompt that runs real programs, each in a namespace of its own
that `bind` and `mount` rearrange; drivers that are files; 9P between the
device's programs, and between the device and a PC over a serial line; an
editor, a display and a keyboard, and a processor that sleeps when there
is nothing to do: all in emulators.** Hamnix Micro boots to Hamnix's shell, `hamsh`, on the
serial console. The shell is an unprivileged process loaded from a file; so
are `ls`, `cat`, `grep`, `vi` and the other 35 programs it runs. It runs in
QEMU's `mps2-an500` (Cortex-M7) and `mps2-an386` (Cortex-M4F) machines and,
as the Feather nRF52840 image, in Renode. On real hardware only the
milestone-3 image has run (a Feather nRF52840, 2026-11-28); nothing of
milestones 4 and 5 has.

```
hamsh$ ls /bin | grep h | wc
hamsh$ cat /proc/self/ns
hamsh$ ns { bind -b /tmp/mybin /bin ; ls }
hamsh$ echo 1 > /dev/gpio/blue
hamsh$ exportfs -s ex /tmp &
hamsh$ mount /srv/ex /n/ex
hamsh$ vi /tmp/notes
hamsh$ ptest loop &
hamsh$ ps
hamsh$ idlestat 3
idlestat, tickless: 3000 ms, of them idle 2999
  processor wake-ups from sleep: 6.6 per second (20)
hamsh$ suspend 30
```

New in milestone 5 (checked by `make test`, `make test-m4`,
`make test-nrf52`):

- **Per-process namespaces** ([`docs/namespaces.md`](docs/namespaces.md),
  with examples to type). Path lookup goes through the mount table of the
  calling process. `bind`, `unmount` and `rfork`'s `RFNAMEG` / `RFCNAMEG`
  are Hamnix's, with its flags (`MREPL`, `MBEFORE`, `MAFTER`, `MCREATE`,
  `MRDONLY`) and its search order; union directories look names up in
  order, list the names of all members, and send a create to the `MCREATE`
  member. The unmodified hamsh's `bind`, `unmount`, `ns { }`, `ns clean`,
  `enter` and `with bind` work; `/proc/<pid>/ns` shows a process's
  namespace as commands that rebuild it. A process that only inherits its
  namespace costs no memory: tables are shared until someone changes them.
- **Drivers as files** ([`docs/devices.md`](docs/devices.md)). A driver
  registers files under `/dev` instead of getting a system call:
  `/dev/i2c/0/ctl` and `data`, `/dev/gpio/<pin>`, `/dev/power/ctl`,
  `/dev/screen/ctl`, `text` and `data`, `/dev/keys`, and the SHT4x as text
  (`cat /dev/sht4x/temperature`). On the QEMU boards the sensor and the
  pins are emulated and a hamsh script drives them with `echo` and `cat`
  (`tests/scripts/devices.hsh`). On the Feather `/dev/gpio/red`, `blue`,
  `button` and 21 header pins are the chip's GPIO registers: `echo 1 >
  /dev/gpio/blue` switches the blue LED (in Renode so far).
- **9P** ([`docs/9p.md`](docs/9p.md)). A 9P2000 client in the kernel:
  the unmodified hamsh's `mount /srv/NAME PATH` attaches a server, and
  everything below the path (open, read, write, create, remove, stat,
  listings, `>` `>>` `<`, running a program) becomes 9P requests. Servers
  post themselves in `/srv`: `exportfs`, a file server in Adder that serves
  a directory of its own namespace, and Hamnix's `p9srv_demo`. Over a
  serial line in both directions: `exportfs /dev/console` lends the
  console's UART to a 9P session with a PC (`tools/hm9p.py ls /dev`,
  `... write /dev/gpio/blue 1`; four zero bytes give the console back), and
  `srv /dev/eia1 pc ; mount /srv/pc /n/pc` mounts a directory that
  `tools/hm9pd.py` serves on the PC (QEMU boards only: they have the second
  serial port). Both PC tools use only the Python standard library.
- **The Feather image fits again.** Its bootloader (0.2.6) writes nothing at
  or above 0xAD000. The board is now compiled with `-Oz`: kernel 127 KB,
  `/bin` 263 KB with 37 programs, 50,448 bytes to spare
  ([`docs/boards/feather-nrf52840.md`](docs/boards/feather-nrf52840.md)).
- `/bin/help` lists the namespace, 9P and device commands.

New in milestone 4:

- **Power** ([`docs/power.md`](docs/power.md)). Tickless idle: with nothing
  runnable the periodic tick is stopped until the next timer is due. An idle
  system is woken about 6 times a second instead of 1000 (measured in QEMU
  and Renode; current cannot be measured without hardware). `suspend` stops
  the whole system until a key or a time.
- **An editor**: Hamnix's `vi`, copied unmodified, tested with scripted
  keystrokes.
- **A display and a keyboard before the hardware**
  ([`docs/display-input.md`](docs/display-input.md)): a frame buffer, an
  e-paper driver model (full and partial refresh, busy, ghosting), a text
  screen for the console, a TCA8418 scanner driver and a key map; with a
  fake panel that leaves PNG frames and a register model of the scanner.
  The tests read the text back out of the PNG.
- **More of the shell**, tested: background jobs and `jobs`, `kill PID`,
  `> file 2>&1`, `def`, history (also across `exit`), Tab completion, and
  Ctrl-C for a whole pipeline. Here-documents do not exist in this hamsh.
- **More programs** from Hamnix, unmodified: `mv touch tail sort uniq tr
  date df free ps kill od tee cut seq vi`; Hamnix Micro's own `sleep setdate
  suspend idlestat keypress`. `/proc` has what `ps`, `free`, `df` and
  `date` read.
- **Holes closed**: a new program starts with zeroed registers, floating
  point included; a process can bind only pipes and files it holds; console
  input survives a pasted block (the sender is held off); the Cortex-M4
  path runs the full kernel test suite (`make test-m4`), which found that
  a context switch could write a thread's registers into its stack guard or
  below a process's memory: the switch now checks for room first. System
  call 266 instructions (milestone 3: 464; milestone 2: 379); context switch
  227 (232; 200), of which about 20 are that check and the one that keeps
  floating-point values from crossing between threads.
- **Audio**: a design note only, [`docs/audio.md`](docs/audio.md).

Works since milestone 3, and is checked by `make test`:

- **Ctrl-C** ends the foreground program or pipeline, whether it loops in
  its own code or waits inside the kernel.
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
- **Hamnix's shell and programs**, copied from Hamnix, under `/bin`, which
  is a read-only table of files inside the kernel image, read in place. The
  shell's source differs from Hamnix's by a patch of 41 lines that makes its
  static tables smaller.
- **Files.** Hamnix's RAM file system at `/` (8 KiB for a small file),
  devices at `/dev`, `/proc`, and Hamnix's FAT32 code at `/sd` over a RAM
  disk that the emulator preloads with an image: read, create, append,
  overwrite, remove, run programs from it.
- **Threads, synchronisation, system calls, memory protection, heap,
  console, C code in the image**: the kernel core of milestone 2. System
  calls are numbered like Hamnix's native interface where the calls match;
  see [`docs/syscalls.md`](docs/syscalls.md).
- Runs end with a status line and a system reset; nothing depends on a
  debugger channel.

Does not exist yet: signals a program can catch, threads inside a process,
shared libraries, a way to compile on the device, USB, PSRAM, a driver for a
real display or keyboard, a persistent file system on flash, audio.

## A second board: the Teensy 4.1 (UNTESTED ON HARDWARE)

`make BOARD=teensy41` builds the same system for a PJRC Teensy 4.1 (NXP
i.MX RT1062): `build/teensy41/hmicro.hex` for the Teensy loader, with the
FlexSPI boot header, the console on `Serial1` (pins 0/1, 115200), the LED on
pin 13 as a sign of life, and `/sd` on the built-in microSD socket. The
i.MX RT drivers (LPUART, GPIO, IOMUXC, clock gates and roots, LPI2C, LPSPI,
uSDHC and the SD card protocol) are in `soc/imxrt/` (shared with the
RT1170 family) and `soc/imxrt1062/`. **None of it has run on a Teensy.**
What can be checked without one is checked by `make test-teensy`: the boot
header against NXP's structures, every register constant and pin-mux
setting against NXP's device files and PJRC's pin table, the SD driver
against QEMU's own uSDHC and SD card models, the other drivers against
register models, and the Teensy's programs in QEMU in the Teensy's memory
map. How to flash it, what the first power-up should show, and the order in
which to check the untested parts: [`docs/boards/teensy41.md`](docs/boards/teensy41.md).

## A third board: the Adafruit Feather nRF52840 Express (first run on hardware 2026-11-28; see its doc for what was and was not tried)

`make BOARD=feather-nrf52840` builds it for Adafruit's Feather nRF52840
Express (Nordic nRF52840: Cortex-M4F at 64 MHz, single-precision FPU,
8-region MPU, 1 MB flash, 256 KB RAM): `build/feather-nrf52840/hmicro.uf2`
for the board's UF2 bootloader (double-tap reset, copy the file to the
FTHR840BOOT drive). It has the console on the TX/RX header pins (UARTE0,
115200), the red LED as a sign of life, and the scheduler tick from RTC1.
Two things are new for this chip. float64 is software (compiler-rt), as the M4F
has no double-precision FPU. Programs are built ROPI/RWPI, so their code
runs in place from flash and only their data and stacks take RAM: the
shell, and a pipeline of five programs beside it, fit in 256 KB. **The
milestone-3 image ran on a Feather on 2026-11-28; later work has only run
in Renode.** `make test-nrf52` boots the unchanged image in
Renode's nRF52840 machine and runs a shell session there, and a 9P session
from the host over the emulated console UART. It also checks every
register constant against Nordic's headers, the image and the UF2 file
against Adafruit's bootloader, and the pins against Adafruit's tables.
Wiring (a USB-to-serial adapter or a Raspberry Pi), first power-up,
bring-up order and memory: [`docs/boards/feather-nrf52840.md`](docs/boards/feather-nrf52840.md).
What another board or chip needs: [`docs/porting.md`](docs/porting.md).

Known shortcomings are listed at the end.

## Build and test

Requirements: `clang` and `ld.lld` (19 is what was used), `llvm-objdump`,
`llvm-objcopy`, `llvm-nm`, `llvm-size`, `llvm-strip`, `qemu-system-arm` (10.0
was used), Python 3.10+, GNU make, `patch`, and mtools (`mformat`, `mcopy`,
`mmd`) for the FAT image. No ARM GCC, no newlib, no compiler-rt.

Hamnix Micro needs the Adder compiler with the `thumbv7em-none-eabihf` target
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
5. the kernel tests: one image, 243 counted checks, including processes
   (isolation, faults, spawn, rfork, exec, wait), pipes, FAT, namespaces
   (bind, unions, rfork's namespace flags), device files, power (tickless
   idle, suspend), the display stack and the keyboard stack, with console
   input typed into the emulated UART by the harness; then the fake panel's
   output is turned into PNG frames and the text read back from the pixels;
6. a scripted session with the kernel monitor (`build/monitor.elf`);
7. an image that faults before the scheduler starts, for the fatal report;
8. a scripted session with the shell: pipelines, redirections, a faulting
   program, the FAT volume, a script file run by a second shell, jobs, kill,
   history, completion, namespaces (`ns { }`, unions, a program replaced
   for one command, `/proc/self/ns` replayed), a script that drives the
   emulated devices through `/dev`, 9P (Hamnix's demo server and
   `exportfs` mounted from `/srv`, redirections onto the mount, a mount as a
   union member and inside `ns { }`, a server killed while mounted; and a
   directory of the host, served by `tools/hm9pd.py` on the board's second
   UART, mounted, written to and compared on the host), the editor, a
   command typed on the emulated key matrix, idle and suspend measurements,
   a pasted block; and the same session as the fake e-paper panel showed it;
9. 9P from the host: `tests/9p/host_test.py` types `exportfs /dev/console`
   and uses the device's tree as a 9P client over the emulated console
   UART (16 checks).

Every check prints `PASS` or `FAIL`; the number of `PASS` lines must equal the
number of checks in the source, so a check that does not run is a failure.
The kernel tests use QEMU's instruction counter as the clock, which makes the
tick-exact timing checks independent of the host's load; the two typed
sessions run in real time.

`make test-m4` runs parts 5, 8 and 9 again on QEMU's Cortex-M4F machine
(`BOARD=qemu-m4`: single-precision FPU, software float64, 8-region MPU).

Other targets: `make size`, `make measure` (code size of small functions
against the same functions in C; sizes of the image and of every program),
`make BOARD=teensy41` and `make test-teensy`, `make BOARD=feather-nrf52840`
and `make test-nrf52` (above; the latter needs Renode, see
`tests/nrf52/renode_session.sh`, and is skipped without it).

`BOARD` selects `boards/<dir>/board.mk`; Adder code imports the board as
`board.board`, and every Adder unit is compiled inside `build/root` (or
`build/<BOARD>/root`), a tree of links to the sources in which `board` is the
selected board directory and in which a board's size patches of copied
Hamnix code are applied (`scripts/mkroot.sh`). The default is
`BOARD=qemu-mps2`; everything above is that board.

## Layout

| Path | What |
|--|--|
| `arch/armv7m/startup.S` | reset stub, fault entry; includes the board's vector table |
| `arch/armv7m/switch.S` | PendSV context switch, SVC entry and exit, first-thread start |
| `arch/armv7m/cpu.S`, `aeabi.S` | special-register access; shims from the EABI helper names to their Adder implementations (also linked into every program) |
| `boards/mps2_an500/` | the QEMU machine: board functions, vector table, linker script, `board.mk` |
| `boards/teensy41/` | the Teensy 4.1: boot header and vector table, linker script, board functions, size patches (`patches/`) |
| `boards/feather_nrf52840/` | the Feather nRF52840 Express: vector table, linker script, board functions, size patches |
| `soc/nrf52/`, `soc/nrf52840/` | nRF52 UARTE, GPIO, RTC tick, delays; nRF52840 addresses, interrupts, clocks |
| `user/rt/prog_rwpi.ld` | the layout of an RWPI program (code in place in flash, data at r9) |
| `scripts/mkuf2.py` | Intel HEX to UF2 |
| `tests/nrf52/` | the Feather checks: register checker, image/UF2 checker, Adafruit facts, the Renode platform and shell session |
| `soc/imxrt/` | i.MX RT drivers for IP blocks the RT1060 and RT1170 share: LPUART, GPIO, IOMUXC, LPI2C, LPSPI, uSDHC; register access and delays |
| `soc/imxrt1062/` | RT1062 addresses, interrupts, clock gates and roots, clock report, watchdogs, caches |
| `drivers/sd/` | SD card protocol over the uSDHC |
| `mm/parena.ad` | the program arena: one MPU-aligned block per process, bookkeeping outside the arena |
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
| `fs/hvfs.ad` | descriptors, path resolution through the caller's namespace, device files, `/bin`, `/fd` names, the FAT glue (Hamnix Micro) |
| `fs/ns.ad` | namespaces: the per-process mount tables, shared copy-on-write; union search order; `/proc/<pid>/ns` |
| `fs/p9c.ad`, `fs/srv.ad` | the kernel's 9P2000 client (what stands behind a mounted name); `/srv` |
| `user/progs/exportfs.ad`, `srv.ad` | a 9P file server for a directory of its own namespace (to `/srv`, or over the console line); posting a serial device in `/srv` |
| `tools/hm9p.py`, `tools/hm9pd.py` | the PC's side of 9P over a serial line: a client for the device's tree, a server for a PC directory (Python standard library) |
| `tests/9p/host_test.py` | the device's tree used from the host over the console UART |
| `drivers/tty/cmsdk_eia.ad` | a second UART as the device file `/dev/eia1` (QEMU boards) |
| `fs/tmpfs.ad`, `fs/fat.ad`, `fs/vfs_mount.ad`, `lib/p9dir.ad`, `lib/9p/` | copied from Hamnix (`fs/HAMNIX_ORIGIN`); `tmpfs.ad` with a size patch |
| `user/hamnix/` | Hamnix's shell and programs, copied; `hamsh.ad` with a size patch |
| `lib/p9.ad`, `perror.ad`, `regex.ad`, `hamcomplete.ad`, `passwd/` | Hamnix libraries those programs import, copied |
| `lib/hamui.ad`, `lib/hamsdl*.ad` | Hamnix Micro stand-ins for Hamnix's GUI libraries (the shell imports them) |
| `user/rt/` | what every program is linked with: entry point, system-call wrappers, heap, linker script |
| `user/progs/` | Hamnix Micro's own programs: `hello`, `halt`, the process test program, a C program |
| `user/sys.ad`, `user/faults.ad` | unprivileged code that is part of the kernel test image |
| `drivers/tty/console.ad` | UART console with line discipline |
| `drivers/i2c/` | software I2C bus, Sensirion platform layer and driver declarations; the bus and the SHT4x as files (`i2cfs.ad`, `sht4xfs.ad`), the emulated SHT4x |
| `fs/devtree.ad`, `drivers/devfiles.ad` | the registry of driver files under `/dev`; the files every board has |
| `drivers/gpio/` | GPIO pins as files; eight emulated pins |
| `init/main.ad`, `init/monitor*.ad` | the system image (init + shell); the kernel monitor image |
| `scripts/mkromfs.sh` | generates the table of ROM files |
| `third_party/` | vendor code with licences and upstream records: Sensirion's C driver; NXP's RT1062 device files, read as data by the checks |
| `lib/cshim/` | the few C library functions C code may use |
| `demo/main.ad` | the milestone-1 run-time self-test |
| `tests/` | kernel test image, harness, link-rule check, measurement fixtures, the FAT image's contents |
| `tests/imxrt/` | the Teensy checks: boot header, register and pin checkers, register models, the driver test image, the uSDHC test on QEMU's i.MX6UL, the Teensy memory test |
| `docs/syscalls.md` | the system-call table and how it differs from Hamnix |
| `docs/namespaces.md` | namespaces: examples, how lookup works, what it costs, differences from Hamnix |
| `docs/devices.md` | the files under `/dev`, which board has which, the Feather's pins, how a driver adds one |
| `docs/9p.md` | 9P: mounting a server, `/srv`, `exportfs`, the device's tree from a PC and a PC's directory on the device; what is and is not tested |
| `docs/boards/teensy41.md` | flashing, wiring, first power-up, bring-up checklist, memory |
| `docs/boards/feather-nrf52840.md` | the same for the Feather nRF52840 |
| `docs/porting.md` | what a new board, chip family or architecture needs |
| `docs/power.md` | tickless idle, suspend, the board's hooks, what was measured |
| `docs/display-input.md` | frame buffer, e-paper driver model, fake panel and PNG frames, text screen; TCA8418 driver, key map, the chip model; the I2C bus interface |
| `docs/audio.md` | design note for an audio path (no implementation) |
| `boards/mps2_an386/` | QEMU's Cortex-M4F machine (`BOARD=qemu-m4`, `make test-m4`) |
| `kernel/power.ad`, `kernel/tickless.ad` | suspend and the power counters; stopping and resuming a SysTick tick |
| `fs/procfs.ad` | `/proc` |
| `drivers/display/` | frame buffer, panel driver model, fake panel, text screen, the console's display thread, the font wrapper |
| `drivers/input/` | TCA8418 scanner driver, its register model, the key map |
| `tests/display/panel2png.py` | the fake panel's records to PNG frames, and text read back from them |
| `tests/m4/` | `make test-m4` |

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

- Only the milestone-3 image has run on hardware (a Feather nRF52840);
  namespaces, device files, 9P, the `-Oz` build, tickless idle and the
  editor have run in emulators only. The QEMU board's tables are sized for its
  16 MB; the Teensy 4.1's (1 MB) are smaller by per-board patches, with the
  limits listed in docs/boards/teensy41.md.
- **No signals.** Ctrl-C ends the foreground command or pipeline (status
  130), `kill PID` any process (137). There is no Ctrl-Z, and no end-of-file
  key while the console is in raw mode: `wc` typed without a redirection
  waits until Ctrl-C. While pasted input is being held off (more than half a
  ring of unread input), Ctrl-C is held with it.
- **`rfork` is vfork.** A built-in command inside a pipeline, a `{ }` block
  after `&`, and everything else where Hamnix's shell forks and keeps running
  shell code works only as far as vfork allows: the child runs in the shell's
  own memory while the shell waits, changes it makes to shell variables stay,
  and it cannot write more than a pipe holds (4 KiB) to a stage that has not
  been started yet. `ns { }` and `enter` blocks run that way (the shell
  waits for them anyway).
- A process block is readable, writable and executable throughout: a program
  can overwrite its own code. Its size is fixed at start; there is no way to
  grow a heap.
- The shell and the editor poll for input; the kernel turns their polling
  into waiting (docs/power.md), which leaves four wake-ups a second while
  idle. `kill` ends a process outright; nothing can be caught.
- The display stack has only ever driven the fake panel; scrolling costs a
  full refresh per line. The keyboard layout is provisional. No SPI
  interface, no nRF52 I2C driver, no persistent file system on flash.
- 9P: one request at a time per connection and no `Tflush`, so a slow
  server holds up everyone using its mount; no authentication, no `wstat`
  (`mv` across a mount copies and removes), four mounted servers at most.
  `ls -l` of a 9P directory shows names only. The serial paths have never
  seen a real line: only the QEMU boards have a second serial port as a
  file, and the console's wire mode on a real UART at 115200 baud is
  untested. No notes a process can catch (`notify`/`noted`): no program
  taken from Hamnix uses them.
- A union is only what was bound at a name (Hamnix's rule): `bind -a` onto
  a directory with nothing bound hides the directory's own files.
- A process is one thread. 32 threads and processes in all, 16 descriptors
  and 16 `/fd` names each, 16 pipes. hamsh quirks seen: no here-documents
  (`cat << EOF` is `cat` on the console); a word ending in `:` starts a
  block, so `cut -d:` must be written `cut -d ":"`; `kill %1` does not
  parse, `kill PID` does; a number such as `01` is printed as `1`.
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

## Licence

AGPL-3.0-or-later. See `LICENSE`.

Files copied from Hamnix (`fs/HAMNIX_ORIGIN`: the file systems, the shell, the
programs and their libraries) are GPL-3.0-or-later by the same author. `third_party/` holds code under its own licences (currently
BSD-3-Clause: Sensirion's driver, NXP's RT1062 device files, Nordic's
nRF52840 device headers; Apache-2.0 WITH LLVM-exception: LLVM compiler-rt's
software double precision; public domain: Daniel Hepper's font8x8), each
with its licence file and an `UPSTREAM` record. Of Adafruit's bootloader (MIT) and Arduino core (LGPL-2.1) nothing
is copied: `tests/nrf52/feather_facts.txt` records extracted numbers (pins,
addresses, keys), with the sources' commits and hashes. Nothing of PJRC's Teensy core is
copied (its licence adds a condition to MIT's); its pin table and boot block
were compared with, and the extracted pin table
(`tests/imxrt/teensy41_pins.txt`) records only facts, with the source's
commit and hash.
