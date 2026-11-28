<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Namespaces

Status: milestone 5, emulators only. Every Hamnix Micro process looks names up in
its own namespace: a small table that says which server stands behind which
name. `bind` and `mount` change the table of the process that calls them,
and nobody else's unless they share it. This is Plan 9's model as Hamnix
implements it (`sys/src/9/port/chan.ad`, `syschan.ad`, `fs/vfs.ad`
`resolve_path`); the flag values, the search order of a union, the argument
order of the system calls and the shell commands are Hamnix's. Where Hamnix Micro
differs it is listed at the end.

## Try it

Everything below can be typed at the `hamsh$` prompt (`make run`).

```
hamsh$ cat /proc/self/ns
bind '#t' /
bind '#c' /dev
bind '#r' /bin
bind '#p' /proc
bind '#f' /sd
bind '#d' /fd
```

That is the boot namespace: six servers bound to six names. A server is
named with `#` and a letter (quote it: `#` starts a comment in the shell):

| Name | Server |
|--|--|
| `#t` | the RAM file system (Hamnix's tmpfs) |
| `#c` | devices: `console`, `null`, `zero`, and the driver trees of [`devices.md`](devices.md) |
| `#r` | the programs built into the kernel image, read in place |
| `#p` | `/proc` |
| `#d` | the `/fd` names of the process that looks |
| `#f` | the FAT volume, on a board that has one |
| `#s` | `/srv`: where 9P servers post themselves ([`9p.md`](9p.md)) |

A server can be used without a name in the namespace: `ls '#c'`,
`cat '#p/version'`.

### bind

`bind SOURCE NAME` makes `NAME` lead to what `SOURCE` names now.

```
hamsh$ mkdir /tmp/a
hamsh$ echo hello > /tmp/a/greeting
hamsh$ mkdir /tmp/x
hamsh$ bind /tmp/a /tmp/x
hamsh$ cat /tmp/x/greeting
hello
hamsh$ unmount /tmp/x
```

The mount point need not exist. `bind '#c' /n/devices` works although there
is no `/n`: the namespace supplies it (`ls /n` lists `devices`).

The source is resolved when the bind is made and stored as a server name
(`/proc/self/ns` shows `bind '#t/tmp/a' /tmp/x`), so a later change of the
namespace does not redirect an existing binding.

### Union directories

`-b` puts the source before what is already at the name, `-a` after it;
plain `bind` replaces everything there.

```
hamsh$ mkdir /tmp/b
hamsh$ echo other > /tmp/b/extra
hamsh$ bind /tmp/a /tmp/x
hamsh$ bind -a /tmp/b /tmp/x
hamsh$ ls /tmp/x
greeting
extra
```

* **Lookup** tries the members in order: `-b` members, the most recently
  bound first; then the plain one; then `-a` members in the order bound. The
  first member that has the name wins.
* **Listing** is every member's names, in that order, each name once.
* **Creating** a file goes to the first member, unless a member was bound
  with `c` in its flag (`-bc`, `-ac`, `-c`): then every create goes to the
  highest-priority such member, even for a name another member has. That is
  how a writable directory is laid over a read-only one:

```
hamsh$ mkdir /tmp/mybin
hamsh$ bind -bc /tmp/mybin /bin
hamsh$ cp /bin/hello /bin/hi        # lands in /tmp/mybin; /bin itself is ROM
hamsh$ hi
```

* `-r` (`-br`, `-ar`) makes a read-only view: reading works, every change
  through that name fails with "read-only binding".

### A namespace for one command, or for a block

`ns { ... }` runs the block in a copy of the namespace; binds made inside
are gone at the closing brace, and were never visible outside.

```
hamsh$ cp /bin/hello /tmp/mybin/seq
hamsh$ ns { bind -b /tmp/mybin /bin ; seq 3 }
hello from a loaded program
  arg: 3
hamsh$ seq 3
1
2
3
```

`ns clean { ... }` starts from nothing: only what the block binds exists.
A block assigned to a name is a template that `enter` runs something in:

```
hamsh$ box = ns clean { bind '#t/tmp/a' / ; bind '#r' /bin }
hamsh$ enter box { ls / }
greeting
fd
bin
hamsh$ enter box { cat /tmp/a/greeting }
cat: cannot open /tmp/a/greeting: file does not exist
```

(The shell itself binds `/fd` in a clean namespace, for the block's
standard streams.) `with bind("/tmp/b", "/tmp/x") as p { ... }` binds in
the shell's own namespace and unbinds at the end of the block.

### Looking at namespaces

`/proc/<pid>/ns` is the namespace of process `<pid>`, `/proc/self/ns` the
reader's own. The text is a list of commands; run in an empty namespace
they build the same one:

```
hamsh$ cat /proc/self/ns > /tmp/saved
hamsh$ echo 'ns clean {' > /tmp/replay
hamsh$ cat /tmp/saved >> /tmp/replay
hamsh$ echo 'cat /proc/self/ns' >> /tmp/replay
hamsh$ echo '}' >> /tmp/replay
hamsh$ echo 'exit 0' >> /tmp/replay
hamsh$ hamsh /tmp/replay
```

## How it works

`fs/ns.ad` holds the tables, `fs/hvfs.ad` uses them. A path a process
passes to `open`, `stat`, `exec`, `chdir`, ... is made absolute and
canonical, and then:

1. The deepest bound name that covers the path is found (`/tmp/x` covers
   `/tmp/x/greeting`; `/` covers everything else). A path that nothing
   covers does not exist: there is no global root behind the namespace.
2. The bindings at that name are the union. Each member turns the path into
   a server name by replacing the covered part: `#t/tmp/a/greeting`.
3. The members are asked in search order whether the name exists; the first
   that has it is used. If none has it the first member's name is used (so
   that a create has somewhere to go, or the open fails there).
4. The server name becomes a key in Hamnix's backend table
   (`fs/vfs_mount.ad`), which routes it to the file system's code.

### Who shares what

| | Namespace of the new process |
|--|--|
| `spawn`, `rfork(RFPROC)` | the same one: a bind by either is seen by both |
| `rfork(RFPROC \| RFNAMEG)` | a copy |
| `rfork(RFPROC \| RFCNAMEG)` | empty |
| `rfork(RFNAMEG)`, `rfork(RFCNAMEG)` without `RFPROC` | the caller itself gets a copy, or an empty one |

Hamnix's shell passes `RFNAMEG` for every command it starts, so every
command would carry a copy. Hamnix Micro copies on write: a "copy" is a new
8-byte group entry that points at the same table, and the table is
duplicated only when one of its users binds or unmounts.

### What it costs (measured, `make test` part 5)

| | bytes |
|--|--|
| per thread: its group number | 4 (in the thread table) |
| namespace groups | 8 each, 32 of them: 256 bytes of static data |
| the boot namespace, 6 binds | 104 bytes of table in a 272-byte heap block |
| a process that inherits its namespace (`RFNAMEG` or not) | 0 bytes of heap |
| the first bind in an inherited namespace (a private copy) | one heap block: 16 bytes of header plus the table, rounded up to 64; 224 bytes of heap for 7 binds |
| one more bind | 9 bytes + the two names + 3 (30 bytes for `/tmp/nsu` -> `#t/tmp/nsb`); the block grows by 64 bytes when it is full |
| limit of one table | 4096 bytes (about 225 short binds); 1024 on the Feather nRF52840 |

## System calls

| Nr | Call | |
|--|--|--|
| 257 | `bind(new, old, flag)` | afterwards the name `new` leads to what `old` names. The shell's `bind SRC DST` calls `bind(DST, SRC, flag)`: in Hamnix `new` is the mount point |
| 258 | `mount(srvfd, afd, old, flag, spec)` | attach the 9P server reached through descriptor `srvfd` at `old` ([`9p.md`](9p.md)) |
| 259 | `unmount(new, old)` | `new` = 0: remove everything bound at `old`. Otherwise remove the one binding of source and mount point, given in either order |
| 285 | `nslabel(op, label, to, from)` | 0: label the newest binding at `to` (`mount ... as LABEL`); 1: remove the binding with that label (`unmount LABEL`) |
| 256 | `rfork(flags)` | `RFNAMEG` 0x008, `RFCNAMEG` 0x080, above |
| 282 | `nsid()` | a number that is the same for processes sharing a namespace |

Flags: `MREPL` 0, `MBEFORE` 1, `MAFTER` 2; or-ed in: `MCREATE` 4, `MCACHE`
8 (stored, no effect, as in Hamnix), `MRDONLY` 16.

Errors are negative errno values with an error string, as everywhere in
Hamnix Micro: `bind failed: source does not resolve in this namespace` (-2),
`mount table full` (-28), `unmount failed: not mounted` (-2),
`read-only binding` (-30).

## Differences from Hamnix

* **The table.** Hamnix's `Pgrp` is a fixed 10 KB structure of 32 entries
  with two 128-byte paths each, copied whole by `rfork(RFNAMEG)`. Hamnix Micro
  packs the entries into one heap block that grows, shares it copy-on-write,
  and limits it by bytes, not entries. `fs/ns.ad` is therefore new code, not
  a copy of `chan.ad`; `fs/vfs_mount.ad` (the backend table underneath) is
  Hamnix's file, unmodified.
* **Order of a union** is the order of the binds. Hamnix orders by table
  slot, which is the same until a slot freed by `unmount` is reused.
* **Directory reads merge** all members of a union (Plan 9). Hamnix lists
  the first member that has the directory, plus the mount points below it.
* **`bind` freezes its source to the member that has it.** Hamnix always
  takes the first member of the source's union, whether the name exists
  there or not.
* **`/proc/<pid>/ns` prints commands the shell reads back**
  (`bind -b '#t/tmp/a' /tmp/x`). Hamnix prints `bind /tmp/x #t/tmp/a -b`:
  mount point first, flags last, unquoted.
* **`unmount(new, old)`** takes its two names in either order; Hamnix's
  kernel wants the mount point first, the reverse of Plan 9 and of the
  shell's usage line.
* **Error returns** are negative errno values (Hamnix: -1); error strings
  hold 63 characters, so Hamnix's longer bind message is shortened.
* **Server letters** are Hamnix Micro's: there is no cpio root (`#r` is the ROM
  program table), no `#e`, `#b`, `#I`; the root of the boot namespace is
  `#t`. Hamnix's named partition stacks (`#distro`, `#by-id`), resource caps
  per namespace and the dentry cache do not exist here.
* **`/fd` names are per process**, not per namespace group as in Hamnix;
  `rfork` always copies them.
* **`rfork` is still vfork.** `ns { }` and `enter` run their block in a
  child that borrows the shell's memory while the shell waits; a child of
  `rfork` may itself `rfork` now (that is what a command inside such a
  block does).
