<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Drivers as files

Status: milestone 5, **emulators only** (the Feather's files drive Renode's
GPIO model, not yet the board's pins). A Hamnix Micro driver is not reached through
a system call of its own. It puts files under `/dev` (the server `#c`), and
a program, or a line typed at the shell, reads and writes them. This is
Plan 9's way and what Hamnix's `dev*.ad` files do; the tree itself is
Hamnix Micro's.

```
hamsh$ ls /dev
console  null  zero  consctl  power  i2c  model  sht4x  gpio  eia1  screen  keys
hamsh$ cat /dev/sht4x/temperature
24.998
hamsh$ echo 1 > /dev/gpio/2
hamsh$ cat /dev/gpio/3
1
```

(`ls` prints one name per line; the QEMU boards are shown. Which files
exist depends on the board, below.)

## The files

| File | Read | Write |
|--|--|--|
| `/dev/console` (`cons`), `null`, `zero` | as before | as before |
| `/dev/consctl` | | `rawon`, `rawoff` (Plan 9's), `wireon`, `wireoff`: the console's mode. In wire mode the console is a plain byte channel: no Ctrl-C, no CR before LF, nothing to the display; `exportfs /dev/console` uses it ([`9p.md`](9p.md)) |
| `/dev/eia1` | bytes that arrived on the second serial port (waits; 0 after 5 s of silence) | bytes to send. For 9P to another machine: `srv /dev/eia1 pc` ([`9p.md`](9p.md)) |
| `/dev/power/ctl` | the idle and wake-up counters (the text of `/proc/power`) | `tickless 0`, `tickless 1` |
| `/dev/i2c/0/ctl` | `addr 44 count 6`, then the result of the last transfer: `ok`, `nack`, or the bytes read in hexadecimal | `w ADDR BYTE...` write bytes; `r ADDR COUNT` read 1..32 bytes; `addr ADDR` and `count COUNT` set what `data` uses. Addresses and bytes are hexadecimal, counts decimal |
| `/dev/i2c/0/data` | one I2C read of `count` bytes from the current address (binary) | one I2C write of the bytes to it |
| `/dev/sht4x/temperature` | `25.000`: degrees Celsius; one measurement per open (about 10 ms) | |
| `/dev/sht4x/humidity` | `56.500`: percent relative humidity | |
| `/dev/sht4x/serial` | the sensor's serial number, 8 hexadecimal digits | |
| `/dev/gpio/<pin>` | `0` or `1`: the level an output is driven to, or the level at an input | `0`, `1` drive it (and make it an output); `in`, `out` |
| `/dev/screen/ctl` | `size 800 480 depth 1 text 100 30 refreshes 12` | `refresh` sends the whole frame again; `clear` empties the text screen |
| `/dev/screen/text` | the characters on the text cells, a line per row | text for the screen, as the console would print it |
| `/dev/screen/data` | the frame buffer (800 x 480 at 1 bit: 48000 bytes, most significant bit left); seekable | pixels, shown at the next refresh, which the write requests |
| `/dev/keys` | | text, typed key by key on the emulated key matrix |
| `/dev/model/sht4x` | `ticks 26214 32768 writes 4 reads 4` | `ticks T RH`: what the emulated sensor measures, in the data sheet's raw units (T = -45 + 175 * ticks / 65535 C, RH = -6 + 125 * ticks / 65535 %) |
| `/dev/model/gpio` | a line per emulated pin: `5 in 1` | `drive PIN LEVEL`: what the outside drives an input to |

A control file takes one command per write. A command it does not
understand fails with `-EINVAL` and the error string "device: not
understood"; a device that does not answer is `-EIO`, "device:
input/output error".

`/proc/power`, `/proc/screen`, `/proc/keys` and `/proc/realtime` are still
there and behave as in milestone 4 (Hamnix's `date` reads
`/proc/realtime`).

## Which board has what

| | every board | QEMU (`qemu-mps2`, `qemu-m4`) | Feather nRF52840 | Teensy 4.1 |
|--|--|--|--|--|
| `power/ctl` | yes | | | |
| `i2c/0/ctl`, `data` | yes: the software bus of `drivers/i2c/bus.ad` | the emulated TCA8418 (0x34) and SHT4x (0x44) are on it | nothing answers (no nRF52 I2C driver yet) | nothing answers until LPI2C is registered as the bus's controller |
| `sht4x/*` | | Sensirion's C driver against the emulated sensor | | |
| `consctl` | yes | | | |
| `gpio/*` | | eight emulated pins, `0`-`1` and `2`-`3` wired together | **the real pins**: `red`, `blue`, `button`, and 21 pins by nRF number (below) | |
| `eia1` | | UART2 of the machine | | |
| `screen/*`, `keys` | | the fake e-paper panel and the key matrix model | | |
| `model/*` | | yes | | |

Nothing here has run on hardware.

## The Feather's pins

On the Feather nRF52840 the files under `/dev/gpio` are the chip's GPIO
registers (`boards/feather_nrf52840/devices.ad`; in the tests, Renode's
model of them):

```
hamsh$ echo 1 > /dev/gpio/blue        # the blue LED on
hamsh$ echo 0 > /dev/gpio/blue
hamsh$ echo 1 > /dev/gpio/red         # the red LED: stops blinking, stays on
hamsh$ cat /dev/gpio/button           # 1, or 0 while the user switch is held
hamsh$ echo 1 > /dev/gpio/26          # header pin D9 high
hamsh$ echo in > /dev/gpio/26 ; cat /dev/gpio/26
```

| File | Pin |
|--|--|
| `red` | the red LED: P1.15 on the Express (P1.09 on the Sense; `board.ad` finds which). It blinks as the board's sign of life **until something is written to this file**; from then on it belongs to whoever writes |
| `blue` | the blue LED, P1.10 (the Express's; not checked for the Sense) |
| `button` | the user switch, P1.02, pulled up: `1` released, `0` pressed. Cannot be written |
| `2 3 4 5 28 30` | A4 A5 A0 A1 A3 A2 |
| `6 7 8 26 27 40 41` | D11 D6 D12 D9 D10 D5 D13 |
| `10`, `11 12`, `13 14 15` | D2; SCL SDA; MOSI SCK MISO |
| `42`, `47` | the LEDs' pins by number |

A number is the nRF pin number, 32 x port + pin (P0.26 = 26, P1.15 = 47),
as in Adafruit's `variant.cpp`, from which the table was taken (read
2026-11-28; the two LED pins and the button are not among the constants
`tests/nrf52/check_image.py` compares). `1`/`0` make the pin an output with
standard drive; `in` an input without pull. Not files: the console's pins
(24, 25), the crystal's, reset, the QSPI flash's, the NeoPixel's. No
analog input, no PWM, no pull configuration, no waiting for an edge.

## A script that drives devices

`tests/scripts/devices.hsh` is run by the test suites of both QEMU boards
(typed into a file, then `hamsh /tmp/dev.hsh`). Part of it:

```
echo "ticks 26214 32768" > /dev/model/sht4x
cat /dev/sht4x/temperature
echo "w 44 89" > /dev/i2c/0/ctl
echo "r 44 6" > /dev/i2c/0/ctl
cat /dev/i2c/0/ctl
echo out > /dev/gpio/2
for v in [1, 0, 1] { echo $v > /dev/gpio/2 ; cat /dev/gpio/3 | tr 10 HL }
```

(`tr 10 HL`, not `tr 01 LH`: the shell reads `01` as the number 1.)

Because `/dev` is a directory in the namespace like any other, device
trees combine with `bind` ([`namespaces.md`](namespaces.md)): `bind -a
/tmp/mydev /dev` adds files of your own after the drivers', and a process
started in `ns clean { bind '#c/gpio' /pins ; ... }` sees the pins and no
other device.

## Writing a driver file

`fs/devtree.ad` is the registry. A driver registers a path below `/dev`
and up to two functions:

```python
from fs.devtree import devtree_add, devtree_text

def _rd(arg: uint64, buf: Ptr[uint8], n: uint64, pos: uint64) -> int64:
    text: Array[4, uint8]
    text[0] = 48 + cast[uint8](my_level(cast[uint32](arg)))
    text[1] = 10
    return devtree_text(&text[0], 2, buf, n, pos)     # the part a reader at pos gets

def _wr(arg: uint64, buf: Ptr[uint8], n: uint64, pos: uint64) -> int64:
    ...
    return cast[int64](n)       # bytes taken, or a negative errno

devtree_add("mydev/level", cast[uint64](&_rd), cast[uint64](&_wr), 3)
```

* The path is a string constant; directories exist because a file lies
  below them. 48 files in all.
* `rd` and `wr` run in the context of the process that reads or writes,
  outside the file system's lock: they may sleep (the SHT4x read does).
* A text file renders its text at every read and lets `devtree_text` cut out
  the part asked for; `cat` ends when a read at the end returns 0. A file
  that must not act twice (a measurement, a bus transfer) acts when `pos`
  is 0 and serves later positions from what it kept.
* `fs/devtree.ad` also has the small formatter (`dt_s`, `dt_u`, `dt_x2`) and
  the command scanner (`dt_word`, `dt_num`, `dt_end`) the drivers here use.
  The shell's `echo` writes the text and the newline in one or two writes;
  a control file ignores a write that is only blanks.
* The files are opened like any device file: descriptors, `lseek` (not
  from the end), `stat`, and redirections (`echo x > /dev/...` goes through
  `openchan` and an `/fd` name).

The drivers of this milestone: `drivers/devfiles.ad` (power, consctl, and it
registers the I2C files), `drivers/tty/cmsdk_eia.ad`, `drivers/i2c/i2cfs.ad`, `drivers/i2c/sht4xfs.ad`,
`drivers/gpio/gpiofs.ad`, `drivers/display/dispfs.ad`; the models:
`drivers/i2c/sht4x_model.ad`, `drivers/gpio/gpio_model.ad`. A board binds
its own in `boards/<board>/devices.ad`, `board_devices_start()`.

## Limits

* One I2C bus, and no lock around it: a script and a driver talking to the
  same device at the same time see each other's transfers.
* The files have no permissions (there is one user) and no exclusive open.
* No interrupts as files: a pin cannot be waited on, only read.
* `/dev/screen/data` is the raw buffer of the panel driver model; nothing
  like Plan 9's `/dev/draw` exists.
