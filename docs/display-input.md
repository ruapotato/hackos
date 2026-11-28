<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# HackOS display and keyboard: the frameworks, and their emulated devices

Status: milestone 4. The code below runs in QEMU (`make test`, `make test-m4`)
against emulated devices, so that the console, the shell and the editor can
be developed on the device's display and keyboard before either exists.
**No real panel and no real keyboard chip has been driven.** The parts are
the ones chosen for the HackerSlide hack pad: a Good Display GDEY0426T82
e-paper panel (800 x 480, SSD1677 controller, SPI) and a TI TCA8418 keypad
scanner (I2C, address 0x34).

```
 console output ──► text screen ──► frame buffer ──► panel driver model ──► a panel driver
 (drivers/tty)      textcon.ad       fb.ad            panel.ad               fakepanel.ad today
                         ▲                               │                        │
                    dispcon.ad: a thread that            └── full / partial ──────┘
                    follows the panel's busy time            refresh, busy, sleep

 a key ──► TCA8418 ──► I2C bus ──► scanner driver ──► key map ──► console input
           (model today) bus.ad     tca8418.ad        keymap.ad    (drivers/tty)
```

## Display

### Frame buffer (`drivers/display/fb.ad`)

1 or 2 bits per pixel, packed most-significant-bit first, rows padded to a
byte: the layout e-paper controllers take and PNG uses. 0 is paper, the
largest value black. 800 x 480 is 48,000 bytes at 1 bit, 96,000 at 2 bits.
The buffer keeps one dirty rectangle: the smallest that holds everything
changed since it was last sent.

### The driver model (`drivers/display/panel.ad`)

E-paper is not a frame buffer one writes to. A refresh takes a third of a
second to seconds and the panel is busy throughout; a full refresh flashes
and cleans, a partial refresh is quick but leaves ghosts that add up; grey
levels need the full waveform. So a panel driver is:

| Function | |
|--|--|
| `init()` | bring the controller up |
| `refresh(fb, x, y, w, h, kind)` | send that rectangle and start a `REFRESH_FULL` or `REFRESH_PARTIAL`; returns the milliseconds the panel is busy now |
| `busy()` | 1 while the last refresh runs |
| `sleep()` | controller to deep sleep (the image stays) |

registered with `panel_register(w, h, bpp, has_partial, max_partials, ...)`.
`display_flush(panel, fb)` is the policy every caller shares:

- clean buffer: nothing is sent;
- busy panel: `DISPLAY_BUSY`, nothing is sent (the caller comes back later);
- full refresh when the buffer is 2-bit grey, when the panel has no partial
  mode, after `max_partials` partial refreshes, on the first refresh, or
  when more than half the screen changed;
- otherwise a partial refresh of the dirty rectangle, widened to whole bytes
  in x (controllers set their RAM window in bytes).

A real driver for the SSD1677 fills in the four functions with SPI commands;
nothing above it changes. That driver is not written: it needs the panel's
datasheet sequence and an SPI controller, and could not be run.

### The fake panel (`drivers/display/fakepanel.ad`)

A stand-in for the panel side: the device's size, a full and a partial
refresh, busy for a while after each (the times are placeholders, not the
real panel's), and it counts everything a driver must not do (sending while
busy, a window outside the panel or off a byte boundary). Each refresh leaves
the machine as a record on a byte sink; on the QEMU boards that is the
second UART, which the test harness writes to a file.

`tests/display/panel2png.py STREAM OUTDIR [--font F --yscale N --keep N]`
replays the records into the image the panel would hold and writes a PNG
after each refresh (1-bit or 2-bit greyscale; standard library only). It
reads every PNG back and compares, and with `--font` it reads the **text**
back from the last frame by matching each character cell against the font:
an independent check from characters to pixels.

To look at the system's screen yourself:

```sh
qemu-system-arm -M mps2-an500 -nographic -no-reboot -serial mon:stdio -serial file:/tmp/panel.bin \
    -device loader,file=build/sd.img,addr=0x20200000 -kernel build/hackos.elf
# ... use the shell, then `halt`
mkdir /tmp/frames && python3 tests/display/panel2png.py /tmp/panel.bin /tmp/frames --keep 5
```

### Text screen and console (`textcon.ad`, `dispcon.ad`)

100 x 30 cells of 8 x 16 pixels on the 800 x 480 panel (the public-domain
font8x8, each row doubled), with the VT100 subset the shell and `vi` use:
cursor addressing and movement, erase in line and screen, inverse, cursor
on/off. A cell is redrawn only when its content changes, so a shell that
repaints its input line at every key costs a partial refresh of one or two
cells. The cursor is a block drawn only into frames that are sent.

The console on a display is asynchronous: output goes into the text screen
at once, and a thread sends what changed when the panel is free, after 30 ms
of quiet so that a burst becomes one refresh. `cat /proc/screen` shows the
text grid.

Known limits: scrolling moves the whole screen, so each scrolled line is a
full refresh (flashing; a real console would rather clear and start at the
top, or scroll by half a screen); one font, one size; no touch (the panel's
FT6336U); the 1 KiB font table is in RAM because the upstream header
declares it writable; `vi` assumes 24 x 80 and uses that corner of the
screen.

A board without a display links none of this: the console calls
`board_console_tee()`, which is empty there.

## Keyboard

### Scanner driver (`drivers/input/tca8418.ad`)

Written from TI's datasheet. It configures which row and column pins carry
keys, enables the key-event and overflow interrupts, and on INT drains the
chip's 10-event FIFO over I2C, clearing the status bits afterwards. I2C
transfers wait, so the INT pin's handler only calls `tca8418_irq()`, which
wakes the keyboard thread. Nothing polls: with no key pressed the thread
sleeps.

### Key map (`drivers/input/keymap.ad`)

Chip row and column to the bytes a serial terminal would send, fed to the
console: letters, digits, Shift, Ctrl (control codes), an Fn layer, caps lock
(Fn + Shift), the D-pad as VT100 arrow sequences, Bksp as DEL. **The layout
is provisional**: it is the keyboard as drawn in the hardware repository
today (48 keys in 4 x 12 folded into the chip's 8 x 10, plus the D-pad); the
newer layout that has been decided is not on the boards yet. Only
`keymap_init()` changes with it. No key repeat yet. All 95 printable ASCII
characters are reachable.

### The model (`drivers/input/tca8418_model.ad`)

The chip's registers behind the software I2C bus: the register pointer,
CFG, INT_STAT with write-1-to-clear, the event FIFO, the keypad pin masks,
INT. `tca_model_key(row, col, down)` is the finger. On the QEMU boards the
model is the system's keyboard: `keypress [-n] TEXT` (or writing to
`/proc/keys`) types text key by key, modifiers held as the layout needs.

## Buses (`drivers/i2c/bus.ad`)

`i2c_write(addr, data, n)` and `i2c_read(addr, data, n)` are the interface
for every I2C device driver on every board. Behind them: devices attached in
software (the models), and one controller a board registers with
`i2c_set_controller(write, read)` for everything else. The i.MX RT's LPI2C
driver exists (`soc/imxrt/lpi2c.ad`, tested against a register model) but
the Teensy board does not register it yet; an nRF52 TWI driver and a shared
SPI interface are **not written** (see the milestone-4 report: Renode models
the nRF52840's legacy TWI and SPI, so a TWI driver could be exercised there
against its SI70xx sensor model; that is the next step for buses).

## What is tested

`make test`, kernel test groups 15 and 16 and the shell session:

- pixels at 1 and 2 bits, clipping, the dirty rectangle;
- the policy: first refresh full, clean sends nothing, busy refused, a
  30-pixel change is a 40 x 10 window at x = 8, the 21st change after 20
  partials is full, most-of-screen is full, grey is always full;
- the fake panel saw no violation; the host received every record, every
  checksum holds, every PNG reads back;
- the 95 printable characters, cursor addressing, an inverse word and the
  last cell (row 30, column 90) are read back **from the image** as written;
  scrolling 40 lines keeps the last 29;
- the whole shell session reaches the panel, and its last frame reads
  `hamsh$ halt 0`;
- the scanner: configuration registers, INT, FIFO drain, overflow at the
  11th event (reported once, the driver recovers), an unconfigured pin, a
  chip that does not answer;
- the map: Shift, Fn, Ctrl, the D-pad, and every printable character typed
  through model, bus, driver and map;
- from the shell: `keypress -n echo ...` types a command on the matrix and
  the shell runs it.
