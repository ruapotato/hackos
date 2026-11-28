<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Hamnix Micro power management

Status: milestone 4. Everything here has run in emulators only. **No current
has been measured, because there is no hardware.** What is measured is how
often the processor is woken, which is what an idle system's consumption
follows; the numbers are at the end.

## Three levels

| Level | What stops | What wakes it | Who decides |
|--|--|--|--|
| **Idle** | the processor, and the periodic tick with it | any interrupt; the next timer that is due | the kernel, by itself, whenever nothing is runnable |
| **Suspend** | the whole system, scheduler included | a byte at the console, or a time; chosen by the caller | a program: `suspend`, system call 520 |
| Off | everything, RAM included | reset or a pin | not implemented: it is a reboot |

## Idle: no tick while nothing runs

The scheduler's tick is 1 ms. Left running, it wakes an idle processor a
thousand times a second to find nothing to do. So when no thread is ready,
the idle thread (`kernel/sched/core.ad`, `_idle_main`):

1. masks interrupts with PRIMASK (an interrupt that becomes pending still
   ends the sleep, and is taken as soon as the mask is lifted, so nothing can
   slip in between the decision and the sleep);
2. looks up when the next timer is due (a sleeping thread, a timed wait);
3. asks the board to stop the tick until then: `board_tick_stop_for(ticks)`;
4. sleeps (`wfi`);
5. asks the board how many tick periods passed: `board_tick_resume()`, and
   moves the kernel's clock by that (`sched_ticks_skipped`), which also wakes
   whatever came due.

Timers still fire on exactly their tick, and the time stays right whether the
sleep ran its length or an interrupt ended it early.

| Board | How the tick is stopped |
|--|--|
| QEMU (`qemu-mps2`, `qemu-m4`) | SysTick is reloaded with the count up to the n-th tick, keeping its phase (`kernel/tickless.ad`); at most 0.67 s at a time (24 bits at 25 MHz) |
| Feather nRF52840 | RTC1's compare is aimed at the n-th tick; the chip sleeps in System ON with LFCLK and RTC1 running (`soc/nrf52/rtc.ad`); at most 60 s at a time |
| Teensy 4.1 | not used: its SysTick counts a 100 kHz reference, so stopping and restarting it could lose 10 us each time. The periodic tick stays. A real implementation would keep time on a GPT |

Two other things had to change, or the processor would not have slept:

- **Hamnix's shell and editor poll.** They wait for a key with `read_nb` +
  `yield` in a loop, and the shell waits for its foreground job with
  `waitpid_jc` + `yield`. On Hamnix that is cooperative scheduling; here it
  kept the processor at 100 % for ever. The kernel now turns the yield after
  16 empty polls in a row into a wait: until console input arrives, a pipe
  is written, a process ends, or 250 ms pass (`docs/syscalls.md`, `yield`).
  The sources are unchanged. An idle shell therefore wakes four times a
  second; that is the floor until the shell blocks in `read`.
- **The reaper thread** looked for work every 20 ms. It is woken when there
  is some, and otherwise looks once a second.

## Suspend

`suspend [SECONDS] [-n]`, or `sys_suspend(ms, sources)`: `sources` bit 0 = a
byte at the console wakes it, bit 1 = `ms` milliseconds. The calling thread
stops the system with interrupts masked and hands over to the board
(`board_suspend`), which disables every interrupt except the wake sources at
the NVIC, sleeps, and reports why it woke and how long it was. The kernel
moves its clock by that time; timers that came due fire at once. The byte
that woke the system is not lost: its interrupt is taken on the way out.

| Board | Suspend |
|--|--|
| QEMU | SysTick is the only timer and has no low-power mode: it runs in the longest stretches it can count, only to keep the time (the processor wakes every 0.67 s) |
| Feather nRF52840 | console is a wake source: UARTE0 keeps receiving, so the 32 MHz clock stays on. Console is not (`-n`): the receiver is stopped and the crystal released; only LFCLK and RTC1 run, and bytes sent meanwhile are lost. RTC1 wakes the processor every 128 s at most to be read before its 24 bits wrap. UNTESTED ON HARDWARE |
| Teensy 4.1 | not implemented (`-EINVAL`) |

What suspend does not do yet: switch off anything outside the chip (a
display's power, a radio), wake from a key matrix or a GPIO pin, or tell
drivers that it is happening. The hook has one place for each (`board_suspend`),
and no driver that would need it exists yet.

## A board's part

| Function | Purpose |
|--|--|
| `board_tick_stop_for(ticks)` | stop the periodic tick for up to `ticks` periods and arrange a wake-up at the end; 1 if done, 0 to keep the tick (then idle is an ordinary `wfi`) |
| `board_tick_resume()` | the tick periods that passed without a tick interrupt; restart the periodic tick |
| `board_suspend(ms, sources, res)` | sleep until a wake source fires; returns the source, `res[0]` = tick periods that passed, `res[1]` = times the processor woke; 0 = not supported |

## Looking at it

`cat /proc/power` shows the counters; `idlestat [SECONDS] [-p]` samples them
across a sleep and prints rates (`-p`: with the periodic tick left on, for
comparison). `cat /proc/uptime` gives seconds up and seconds idle.

## Measured (emulators)

All figures are counts of events, not current.

| Where | What | Tickless idle | Periodic tick |
|--|--|--|--|
| QEMU Cortex-M7, kernel test, instruction-counter clock | a thread sleeps 2000 ticks, nothing else runs | 0 tick interrupts, 5 wake-ups; an independent timer (CMSDK timer 0) measures 50,000,248 counts for the 50,000,000 of 2 s: 5 ppm | 2000 tick interrupts, 2000 wake-ups |
| QEMU Cortex-M7, shell session, real time | 3 s at the shell with `idlestat` asleep | about 5 wake-ups per second | about 1000 |
| Renode nRF52840 (the Feather image), shell session | the same | 6.6 wake-ups per second, 0.3 tick interrupts per second | 1000.3 |
| QEMU, kernel test | `suspend` 1500 ms by timer | clock moved 1500 ticks; the processor woke 3 times (SysTick's 0.67 s) | |
| Renode nRF52840 | `suspend 30`, a byte sent after 2 s | woke: console, after 2002 ms, the processor woken once | |
| Renode nRF52840 | `suspend 2 -n` (receiver off, crystal released) | woke: timer, after 2000 ms | |

The remaining wake-ups of an idle system are: the shell's poll (4 per
second), the reaper (1 per second), and on the Feather the LED heartbeat
thread (2 per second).

What the emulators cannot show: the currents themselves (the figures for
System ON sleep with the RTC running, and for the crystal oscillator and the
UARTE receiver, are in Nordic's product specification; none was looked up or
measured for this note), how long the crystal takes to come back, and
whether the first byte after a console wake is received intact. Those are
for the first board on the bench.
