<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# HackOS system calls

Status: milestone 2, emulator only. This is the interface between unprivileged
threads and the kernel as it exists now; it will grow with program loading.

## How a call is made

A thread calls `hackos_syscall(nr, a0, a1, a2, a3, a4, a5)`
(`arch/armv7m/switch.S`), normally through a wrapper in `user/sys.ad`. The stub
is two instructions, `svc #0` and a return; all the work is in the calling
convention:

| Value | Where it is at the `svc` (Adder convention, every value 64 bits) |
|--|--|
| call number | `r0` (low word), `r1` (high word, ignored) |
| `a0` | `r2` (low), `r3` (high) |
| `a1` ... `a5` | the caller's stack, 8 bytes each, low word first |
| result | `r0` (low), `r1` (high) |

The processor pushes `r0`-`r3`, `r12`, `lr`, `pc` and `xPSR` onto the caller's
stack when it takes the exception, so the kernel finds the number and `a0` in
that frame and `a1`... directly above it (above the floating-point area too, if
the caller had floating-point state, and above one padding word if the stack
needed realigning). The kernel only reads as many stack arguments as the call
takes, and checks that they lie in memory the caller may read.

The call does not run inside the exception handler. The handler moves the
thread to its kernel stack, makes it privileged and returns to thread mode in
the kernel's dispatcher, so a system call is ordinary preemptible kernel code
and may block. A second, kernel-only `svc #1` returns to the caller. Cost,
measured: see the milestone report.

Results follow Hamnix's convention for its POSIX-shaped calls: zero or a
positive value on success, a negative Linux errno on failure, and an error
string per thread that `errstr` returns.

Pointer arguments from an unprivileged caller are checked against what the
memory protection unit lets that caller touch: the user arena for reading and
writing, the image's code and constants for reading. Anything else is
`-EFAULT` (-14) and the kernel does not touch the memory.

## The table

Numbers are Hamnix's native numbers (`arch/x86/kernel/syscall.ad` at commit
`1c5d976a`) for every call both systems have, so a program written against
Hamnix's `sys_*` stubs keeps its meaning. HackOS-only calls start at 512.

| Nr | Wrapper in `user/sys.ad` | Behaviour | Compared with Hamnix |
|--|--|--|--|
| 0 | `sys_putc(c)` | one byte to the console | same |
| 1 | `sys_exit(code)` | ends the calling **thread**; the code goes to whoever joins it | Hamnix ends the process |
| 2 | `sys_get_jiffies()` | 100 Hz ticks since boot | same |
| 4 | `sys_getpid()` | the thread id | there are no processes yet; see below |
| 5 | `sys_open(path)` | open for reading; a directory reads as `NAME\n` lines | same |
| 6 | `sys_read(fd, buf, n)` | bytes read, 0 at end of file; blocks on the console | same |
| 7 | `sys_close(fd)` | | same |
| 8 | `sys_write(fd, buf, n)` | bytes written | same |
| 9 | `sys_lseek(fd, off, whence)` | whence 0/1/2; `-ESPIPE` on devices | same |
| 13 | `sys_open_write(path)` | create or truncate, open for writing | same |
| 16 | `sys_dup(fd)` | lowest free descriptor | same |
| 17 | `sys_dup2(old, new)` | | same |
| 19 | `sys_chdir(path)` | per thread | per task in Hamnix |
| 20 | `sys_getcwd(buf, n)` | bytes including the NUL | same |
| 21 | `sys_unlink(path)` | file or empty directory; **`-EBUSY` if the file is open** | Hamnix removes an open file |
| 22 | `sys_mkdir(path)` | | same |
| 23 | `sys_read_nb(fd, buf, n)` | > 0 bytes, 0 = nothing yet, -1 = end of file | same contract |
| 24 | `sys_yield()` | give up the rest of the time slice | Hamnix schedules cooperatively; HackOS also preempts |
| 260 | `sys_create(path, flags, mode)` | `mode & DMDIR` makes a directory, else create/truncate and open read-write | same |
| 261 | `sys_stat_p9(path, buf, n)` | a 9P2000 stat record; bytes written | same record layout; uid/gid are the string `hackos`; times are seconds |
| 262 | `sys_fstat_p9(fd, buf, n)` | the same for a descriptor (the name is empty) | same |
| 263 | `sys_remove(path)` | as `unlink` | same |
| 265 | `sys_errstr(buf, n)` | copies the thread's last error string | read only; Hamnix can also install a string |
| 302 | `sys_mmap(addr, len, prot, flags, fd, off)` | **anonymous memory only** (`fd` = -1): `len` zeroed bytes from the user arena, 4 KiB aligned | no file mappings, `addr` and `prot` are ignored: there are no page tables |
| 304 | `sys_munmap(addr, len)` | frees a block `mmap` returned (whole blocks only) | |
| 308 | `nanosleep({sec, nsec})` | rounded up to scheduler ticks (1 ms) | same structure |
| 512 | `sys_thread_spawn(entry, arg, prio, stack)` | new unprivileged thread running `entry(arg)`; returns its id | HackOS only |
| 513 | `sys_thread_join(tid, &code)` | waits for a thread and collects its exit code | HackOS only |
| 514 | `sys_rename(old, new)` | | Hamnix renames through `wstat` (266), which HackOS does not implement |
| 515 | `sys_gettid()` | the thread id | HackOS only |
| 516 | `sys_sleep_ms(ms)` | | HackOS only |

Any other number returns `-ENOSYS` (-38) with the error string
`unknown syscall` (Hamnix returns -1).

A thread ended by a fault has exit code 139 (memory access, including a stack
overflow), 135 (bus fault) or 132 (undefined instruction and other usage
faults): 128 plus the signal number a Unix shell would show.

## What is deliberately different without an MMU

* **No `fork`, no `rfork(RFPROC)`.** A copy of the caller's memory cannot be
  made cheaply or transparently when every pointer is a physical address.
  HackOS starts new activities with `thread_spawn` today; milestone 3 adds
  `spawn(path, argv)` (load a program into fresh memory and start it) and a
  `vfork`-style call for Hamnix's shell, where the child borrows the parent's
  memory until it calls `exec` or exits.
* **No processes yet.** All unprivileged threads share one address space (the
  user arena) and one program image. `getpid` therefore returns the thread id.
  Descriptors and the working directory are per thread, copied from the
  creator at `thread_spawn` (as `rfork(RFFDG)` would).
* **No namespaces.** There is one mount table: tmpfs at `/` and devices at
  `/dev`. `bind`, `mount`, `unmount` and Hamnix's `/fd` device do not exist.
* **`mmap` is an allocator.** No file mapping, no protection changes, no fixed
  addresses.
* **Open modes.** As in Hamnix, `open` is read-only and `open_write` creates or
  truncates. The kernel-internal `vfs_open(path, mode)` also has read-write
  and append; only `create` exposes read-write to user threads so far.

## Not implemented (Hamnix has them)

`execve` (10), `waitpid` (12), `pipe` (14), `rfork` (256), `bind`/`mount`/
`unmount` (257-259), `fd2path` (264), `wstat`/`fwstat` (266-267), the `/fd`
calls (`fdbind` 278, `pipechan` 280, `openchan` 281, ...), `clock_gettime`
(307), `waitfds` (313), sockets, services, graphics, and the rest. The
milestone report lists what Hamnix's shell needs of these.
