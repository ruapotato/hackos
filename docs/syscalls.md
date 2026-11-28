<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Hamnix Micro system calls

Status: milestone 4, emulators only (QEMU's Cortex-M7 and Cortex-M4 machines, Renode's nRF52840). This is the interface between unprivileged
code and the kernel: programs loaded from the file system (processes), and
the unprivileged threads that the kernel test image carries inside itself.

## How a call is made

A program calls `hmicro_syscall(nr, a0, a1, a2, a3, a4, a5)`, normally through
a wrapper: `user/rt/rt.ad` for programs (it supplies the `sys_*` names Hamnix
programs declare as `extern def`), `user/sys.ad` for threads inside the kernel
image. The stub is two instructions, `svc #0` and a return; all the work is in
the calling convention:

| Value | Where it is at the `svc` (Adder convention, every value 64 bits) |
|--|--|
| call number | `r0` (low word), `r1` (high word, ignored) |
| `a0` | `r2` (low), `r3` (high) |
| `a1` ... `a5` | the caller's stack, 8 bytes each, low word first |
| result | `r0` (low), `r1` (high) |

A C program can make the same call: declared with `uint64_t` parameters, the
C calling convention puts every value where Adder expects it
(`user/progs/crel.c`).

The processor pushes `r0`-`r3`, `r12`, `lr`, `pc` and `xPSR` onto the caller's
stack when it takes the exception, so the kernel finds the number and `a0` in
that frame and `a1`... directly above it (above the floating-point area too, if
the caller had floating-point state, and above one padding word if the stack
needed realigning). The kernel only reads as many stack arguments as the call
takes, and checks that they lie in memory the caller may read.

The call does not run inside the exception handler. The handler moves the
thread to its kernel stack, makes it privileged and returns to thread mode in
the kernel's dispatcher, so a system call is ordinary preemptible kernel code
and may block. A second, kernel-only `svc #1` returns to the caller. The
handler also keeps the caller's `r4`-`r11` in the thread structure: `rfork`
starts the child with a copy of them.

Results follow Hamnix's convention for its POSIX-shaped calls: zero or a
positive value on success, a negative Linux errno on failure, and an error
string per thread that `errstr` returns.

Pointer arguments from an unprivileged caller are checked against what the
memory protection unit lets that caller touch (`kernel/uaccess.ad`): for a
process its own memory block and nothing else; for a thread inside the kernel
image the shared arena, plus the image's code and constants for reading.
Anything else is `-EFAULT` (-14) and the kernel does not touch the memory.

## The table

Numbers are Hamnix's native numbers (`arch/x86/kernel/syscall.ad` at commit
`1c5d976a`) for every call both systems have, so a program written against
Hamnix's `sys_*` stubs keeps its meaning. Hamnix Micro-only calls start at 512.

### Files

| Nr | Wrapper | Behaviour | Compared with Hamnix |
|--|--|--|--|
| 0 | `sys_putc(c)` | one byte to the console | same |
| 2 | `sys_get_jiffies()` | 100 Hz ticks since boot | same |
| 5 | `sys_open(path)` | open for reading; a directory reads as `NAME\n` lines | same |
| 6 | `sys_read(fd, buf, n)` | bytes read, 0 at end of file; blocks on the console and on an empty pipe | same |
| 7 | `sys_close(fd)` | | same |
| 8 | `sys_write(fd, buf, n)` | bytes written; blocks on a full pipe; `-EPIPE` (-32) when the pipe has no reader | no SIGPIPE in either |
| 9 | `sys_lseek(fd, off, whence)` | whence 0/1/2; `-ESPIPE` on devices and `/fd` names | same |
| 13 | `sys_open_write(path)` | create or truncate, open for writing | same |
| 16 | `sys_dup(fd)` | lowest free descriptor | same |
| 17 | `sys_dup2(old, new)` | | same |
| 19 | `sys_chdir(path)` | per process | same |
| 20 | `sys_getcwd(buf, n)` | bytes including the NUL | same |
| 21 | `sys_unlink(path)` | file or empty directory; **`-EBUSY` if the file is open or bound at an `/fd` name** | Hamnix removes an open file |
| 22 | `sys_mkdir(path)` | tmpfs only | same |
| 23 | `sys_read_nb(fd, buf, n)` | > 0 bytes, 0 = nothing yet, -1 = end of file | same contract |
| 260 | `sys_create(path, flags, mode)` | `mode & DMDIR` makes a directory, else create/truncate and open read-write | same |
| 261 | `sys_stat_p9(path, buf, n)` | a 9P2000 stat record; bytes written | same record layout; uid/gid are the string `hmicro`; times are seconds |
| 262 | `sys_fstat_p9(fd, buf, n)` | the same for a descriptor (the name is empty) | same |
| 263 | `sys_remove(path)` | as `unlink` | same |
| 265 | `sys_errstr(buf, n)` | copies the caller's last error string | read only; Hamnix can also install a string |
| 514 | `sys_rename(old, new)` | tmpfs only | Hamnix renames through `wstat` (266), which Hamnix Micro does not implement |

### Processes

| Nr | Wrapper | Behaviour | Compared with Hamnix |
|--|--|--|--|
| 1 | `sys_exit(code)` | ends the caller; descriptors, `/fd` names and memory are released at once, the code waits for `waitpid` | same |
| 4 | `sys_getpid()` | the process id (a process is one thread; the ids are the same numbers) | same |
| 10 | `sys_execve_env(path, argv, envp)` | replaces the caller's program; returns only on failure (`-ENOENT`, `-ENOEXEC` -8, `-ENOMEM`, `-E2BIG` -7) | same; the program must be a position-independent ELF for this machine |
| 12 | `sys_waitpid(pid)`, `sys_waitpid_nb_raw(pid, flags)` | the exit code of process `pid` once it has ended, and the process is gone; `flags` bit 0: `-EAGAIN` (-11) instead of waiting; `-ECHILD` (-10) for an unknown pid | same |
| 24 | `sys_yield()` | give up the rest of the time slice. **After 16 empty polls in a row** (a `read_nb` that found nothing, or a `waitpid_jc` that found its process still running) **it waits instead**: until console input arrives, a pipe is written, a process ends, or 250 ms pass. A read that returns data, or any write, ends the streak | Hamnix schedules cooperatively; Hamnix Micro also preempts. The wait exists because Hamnix's shell and editor wait for a key, and the shell for its foreground job, by polling and yielding; left alone that keeps the processor awake for ever |
| 256 | `sys_rfork(flags)` | **vfork**: needs `RFPROC`; the child runs on the parent's memory with its own descriptors and `/fd` names, and the parent is suspended until the child calls `exec` or `exit`. `RFNOWAIT` (0x100) detaches the child. Other flag bits are ignored | Hamnix copies the address space (copy on write) and can also change namespaces; see below |
| 288, 289 | `sys_getuid()`, `sys_getgid()` | 1: there is one user, the owner | same value for Hamnix's hostowner |
| 290 | `sys_setuid(uid)` | succeeds for the current uid only | |
| 297 | `sys_setpgid(pid, pgid)` | puts a process in a group (`pgid` 0: its own); children inherit it | same |
| 298 | `sys_tcsetpgrp(pgid)` | names the group that has the console: Ctrl-C ends every process in it with exit code 130 | Hamnix posts SIGINT, which a program may catch; also Ctrl-Z |
| 299 | `sys_waitpid_jc(pid, &status)` | never waits: `pid` when the process has ended (`status = (code & 0xFF) << 8 \| 1`, and it is gone), 0 while it runs, `-ECHILD` | no stopped or continued states |
| 308 | `nanosleep({sec, nsec})` | rounded up to scheduler ticks (1 ms) | same structure |
| 516 | `sys_sleep_ms(ms)` | | Hamnix Micro only |
| 517 | `sys_spawn(path, argv)` | a new process running `path` with the caller's descriptors, `/fd` names and directory; returns its id. No fork involved: the native way to start a program | Hamnix Micro only (Hamnix retired its `spawn` call in favour of `rfork` + `exec`) |
| 518 | `halt(status)` | prints `[hmicro] exit status N` and resets the machine | Hamnix Micro only |
| 520 | `sys_suspend(ms, sources)` | stops the whole system until a wake source fires: `sources` bit 0 = a byte at the console, bit 1 = after `ms` milliseconds. Returns the source that fired (1 or 2); `-EINVAL` when nothing could end it or the board cannot suspend. The clock is moved by the time spent. See [`power.md`](power.md) | Hamnix Micro only |

A new program starts with every register zero that the kernel does not use
to pass something in (argc and argv in `r0`-`r3`, the static base in `r9` of
an RWPI program): the callee-saved core registers and all floating-point
registers and FPSCR, after `spawn` and after `exec`. A process never sees
floating-point values another process computed.

A process ended by Ctrl-C has exit code 130; by a note (below) 137 (`kill`),
130 (`interrupt`), 129 (`hangup`) or 143 (`term`).

A process ended by a fault has exit code 139 (memory access, including a stack
overflow), 135 (bus fault) or 132 (undefined instruction and other usage
faults): 128 plus the signal number a Unix shell would show. The kernel prints
one line naming the process.

### `/fd` names: pipes and redirections

Hamnix's shell does not build pipelines from `pipe` and `dup`. Every process
has sixteen names `/fd/0` ... `/fd/15`; each is bound to the console, one end
of a pipe, a file, or nothing, and a descriptor opened on `/fd/N` resolves the
name at every read and write, in the process that makes the call. So a parent
can redirect a child after the child exists. Hamnix Micro implements this part of
Hamnix's namespace model and nothing else of it.

| Nr | Wrapper | Behaviour |
|--|--|--|
| 278 | `sys_fdbind(pid, n, kind, arg)` | bind `/fd/n` of process `pid` (0 = the caller; otherwise a child of the caller). `kind`: 0 nothing, 1 console, 2 read end of pipe `arg`, 3 write end of pipe `arg`, 4 file channel `arg`, 5 whatever `/fd/arg` is bound to (dup), 6 file channel written at its end (append), 7 device or ROM-file channel `arg`. **A process can bind only what it holds** (`-EPERM` otherwise): a pipe it created with `pipechan` or already has at one of its names; a file it opened with `openchan` or already has bound. A child of `rfork` that has not exec'ed counts as its parent. A dup (5) of a file makes both names write at the end of the file, so `> file 2>&1` keeps the two streams in order |
| 280 | `sys_pipechan()` | a new pipe (4 KiB), as a slot number for `fdbind`; it lives while a name is bound to either end |
| 281 | `sys_openchan(path, mode)` | open a file as a channel for `fdbind`: mode 0 existing, 1 create or truncate, 2 create and keep. tmpfs files, devices, and (mode 0) the programs under `/bin`. The caller is granted the right to bind the result (until it ends or the file is removed; the kernel remembers 32 grants and overwrites the oldest) |
| 282 | `sys_nsid()` | 1 |
| 287, 324 | `sys_fdslot_kind(pid, n)`, `sys_fdslot_arg(pid, n)` | what a name is bound to |

The bindings are copied to a child with every pipe end counted, and dropped
when the process ends; that is what delivers end-of-file to a reader and
`-EPIPE` to a writer.

One rule exists only because of vfork. Hamnix's shell binds a child's standard
streams *after* `rfork` + `exec` and relies on Hamnix's cooperative scheduler
not to run the child before the parent gives up the processor. Hamnix Micro
preempts, so a child that came from `rfork` is **held after `exec`** until its
parent next yields, waits, sleeps, reads or forks again. `sys_spawn` children
are not held.

### /proc

Text files rendered by the kernel when they are opened (`fs/procfs.ad`). They
are what Hamnix's `ps`, `free`, `df` and `date` read, with Hamnix Micro's content.

| File | Content |
|--|--|
| `/proc/version` | system and board |
| `/proc/uptime` | seconds up, seconds idle |
| `/proc/tasks` | every thread and process: id, parent, state, priority, kind, memory block, kernel and user stack used, CPU time, name |
| `/proc/meminfo` | `MemTotal` and `MemFree` (kernel heap plus program arena), then both separately with their peaks |
| `/proc/mounts` | the mount table |
| `/proc/realtime` | `YYYY-MM-DDTHH:MM:SSZ <seconds since 1970>`, or `unavailable 0` until the clock has been set. **Writing** a number of seconds sets it (`/bin/setdate`) |
| `/proc/power` | idle and wake-up counters ([`power.md`](power.md)). Writing `tickless 0` or `tickless 1` switches tickless idle |
| `/proc/screen` | the text on the display's character cells, or `no display` |
| `/proc/keys` | write-only, on a board with the emulated keyboard: the text written is typed through the key matrix model |
| `/proc/<pid>/note` | write-only: `kill`, `interrupt`, `hangup` or `term` ends process `<pid>`. This is all there is of Plan 9's notes: nothing can be caught. Hamnix's shell built-in `kill PID` writes `kill` here |

### Memory and threads

| Nr | Wrapper | Behaviour |
|--|--|--|
| 302 | `sys_mmap(addr, len, prot, flags, fd, off)` | **anonymous memory only** (`fd` = -1). In a process this is not a system call: `user/rt/rt.ad` hands out the program's own heap, whose size is fixed when the program is linked (`HEAP_<name>` in the Makefile). In a thread of the kernel image it allocates from the shared arena |
| 304 | `sys_munmap(addr, len)` | frees a block `mmap` returned (whole blocks only) |
| 512 | `sys_thread_spawn(entry, arg, prio, stack)` | threads of the kernel image only (the tests); `-ENOSYS` in a process |
| 513 | `sys_thread_join(tid, &code)` | |
| 515 | `sys_gettid()` | |

### Accepted but empty

So that Hamnix's shell links and runs: `bind` (257), `mount` (258), `unmount`
(259) return `-ENOSYS` with the error string "no namespaces on this system";
`svc_ctl` (296) answers "nothing pending" to the shell's idle poll and
`-ENOSYS` to everything else. Any other number returns `-ENOSYS` (-38) with
the error string `unknown syscall` (Hamnix returns -1).

## What is deliberately different without an MMU

* **`rfork` is vfork.** A copy of the caller's memory cannot be made cheaply
  or transparently when every pointer is a physical address. The child gets
  its own descriptors and `/fd` names but runs in the parent's memory, on the
  parent's stack, until it calls `exec` or `exit`. The kernel copies the
  parent's stack aside and puts it back when the parent resumes, so nothing
  the child does to the stack survives; what it writes to globals does.
  A child that keeps running shell code instead of calling `exec` (a built-in
  inside a pipeline, a subshell block) therefore runs *as part of the parent's
  memory* and the parent waits for it.
* **A program's memory is fixed when it starts.** One block holds stack,
  code, data and heap; the stack size (`-z stack-size`) and heap size are
  link-time choices. There is no `brk`, and `mmap` cannot grow the block.
* **Programs are position-independent.** `exec` accepts ELF `ET_DYN` files
  with `R_ARM_RELATIVE` relocations only (`clang -fPIE`, `ld.lld -pie`;
  `user/rt/prog.ld`).
* **No namespaces.** One mount table: tmpfs at `/`, devices at `/dev`,
  programs at `/bin`, `/fd`, and a FAT volume at `/sd` when there is one.
* **Open modes.** As in Hamnix, `open` is read-only and `open_write` creates or
  truncates. The kernel-internal `vfs_open(path, mode)` also has read-write
  and append; only `create` exposes read-write to programs so far.
* **No signals; notes only end a process.** Ctrl-C at the console ends the
  foreground group outright (a process running its own code is ended at the
  next timer tick, one inside a system call when the call returns; a wait on
  the console, a pipe or a child gives up at once). Hamnix's shell names a
  group for a single foreground command but not for a pipeline, so with no
  group (or an empty one) Ctrl-C ends **the processes that a waiting process
  is waiting for** and that are still in its group: the stages of a pipeline,
  or a script's shell together with what it runs; a background job has its
  own group and is spared. Only when that finds nobody is Ctrl-C a byte for
  whoever reads the console (the shell's editor). A note written to
  `/proc/<pid>/note` ends that process the same way. A program can catch
  neither.

## Not implemented (Hamnix has them)

`pipe` (14; use `pipechan` + `fdbind`), `kill` (15; write to `/proc/<pid>/note`),
`fd2path` (264), `wstat`/`fwstat` (266-267), `srv_open` (276), `nslabel`
(285), `svc_publish` (291), `setuid_auth` (300), `clock_gettime` (307),
`waitfds` (313), `listdir_records` (318), `chan_dir_mode` (319: `ls -l` falls
back to the plain listing), sockets, services, graphics, and the rest.
