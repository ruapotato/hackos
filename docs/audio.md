<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 David Hamner -->
# Hamnix Micro audio path: design note (no implementation)

Status: design only, written 2026-11-27. Nothing here is built or tested.
There is no audio code in the tree. This note proposes an I2S output path
for the nRF52840 and the i.MX RT1062, a `/dev/audio` interface, a first
decoder, and a staged plan. Section 5 lists what was not verified.

Every number is tagged: **[M]** measured by the cited source on hardware,
**[S]** published by the source from a simulator, **[C]** claimed by the
source without figures, **[E]** extrapolated here (not measured by anyone),
**[D]** derived here by arithmetic from a datasheet or source file. Tags
like [S1] point to the source list in section 6.

## 1. The I2S output path

### 1.1 Shape

```
file -> decoder process -> write(/dev/audio) -> kernel ring (s16le stereo)
     -> driver interrupt copies ring -> DMA block -> I2S/SAI -> DAC or amp
```

The ring always holds signed 16-bit little-endian interleaved stereo: what
the decoders produce, and on the nRF52840 also the DMA format (one 32-bit
word holds two 16-bit samples [S1]), so ring to DMA is a plain copy.

### 1.2 nRF52840 I2S

The chip has one I2S peripheral with EasyDMA and no DAC. The PDM peripheral
is an input (microphones) and is of no use for playback. Facts from the
product specification [S1]:

* Master mode generates MCK, LRCK and SCK. `MCK = 32 MHz / divider`
  (`CONFIG.MCKFREQ`), `LRCK = MCK / CONFIG.RATIO`,
  `SCK = 2 * LRCK * SWIDTH`. `CONFIG.MCKEN` must be set in master mode,
  whether or not the MCK pin is routed.
* `RATIO` must be at least `2 * SWIDTH` and a whole multiple of it.
* Sample widths 8, 16, 24 bits; original I2S or left/right aligned format.
* `TXD.PTR` is double-buffered. `RXTXD.MAXCNT` is the block length in
  32-bit words (two 16-bit samples, or one 24-bit sample sign-extended,
  per word). A `TXPTRUPD` event fires each time the hardware copies the
  pointer into its internal buffer; the driver then writes the pointer for
  the block after that. The buffer must be in Data RAM.
* The specification does not say what is sent if the pointer is not
  updated in time. The usual report is that the previous block repeats;
  this must be observed on hardware (section 5).

A driver therefore needs: pin selects (`PSEL.SCK`, `LRCK`, `SDOUT`,
optionally `MCK`), `CONFIG.MODE/TXEN/MCKEN/MCKFREQ/RATIO/SWIDTH/FORMAT/
CHANNELS`, two DMA blocks owned by the kernel, the `TXPTRUPD` and `STOPPED`
interrupts, `TASKS_START/STOP`, and a request for the crystal oscillator
(HFXO) while playing, because MCK is divided from HFCLK and the internal
RC oscillator is not accurate enough for pitch (accuracy figure not
re-checked, section 5).

**Reachable sample rates.** The MDK header in
`third_party/nordic-mdk-nrf52840` defines 13 dividers (8, 10, 11, 15, 16,
21, 23, 30, 31, 32, 42, 63, 125) and 9 ratios (32 to 512). The nRF52840
has no audio PLL (the fractional ACLK source belongs to the nRF5340), so
only quotients of 32 MHz exist. Best settings, computed from those two
lists [D]; the 16-bit rows for 16, 32 and 44.1 kHz match Nordic's own
example table [S1]:

| Wanted (Hz) | 16-bit: setting, actual, error | 24-bit: setting, actual, error |
|--|--|--|
| 8000 | DIV125 x32, 8000.0, exact | DIV21 x192, 7936.5, -0.79 % |
| 11025 | DIV15 x192, 11111.1, +0.78 % | same |
| 16000 | DIV63 x32, 15873.0, -0.79 % | DIV21 x96, 15873.0, -0.79 % |
| 22050 | DIV15 x96, 22222.2, +0.78 % | same |
| 24000 | DIV21 x64, 23809.5, -0.79 % | none within 7 % |
| 32000 | DIV31 x32, 32258.1, +0.81 % | DIV21 x48, 31746.0, -0.79 % |
| 44100 | DIV23 x32, 43478.3, **-1.41 %** | DIV15 x48, 44444.4, +0.78 % |
| 48000 | DIV21 x32, 47619.0, -0.79 % | none within 7 % |

Only 8 kHz (and 15625, 31250, 50000 Hz and similar) is exact. Consequences:

* 44.1 kHz material played as 16-bit runs 1.41 % slow, about 25 cents flat
  [D]. Audible next to a reference, tolerable for a hack pad's speaker.
* The 24-bit width halves the error (+0.78 %, 13 cents sharp) but doubles
  the DMA memory (one sample per 32-bit word) and needs a DAC that accepts
  48 bit clocks per frame.
* Exact rates need either a software resampler (44100 to 43478 is a ratio
  of about 1.0143; linear interpolation is cheap, a good polyphase filter
  is not) or an external master clock with the nRF52840 as I2S slave.
  Neither is proposed for the first version: the driver reports the actual
  rate and plays slightly off pitch.

### 1.3 i.MX RT1062 SAI

The RT1062 has SAI blocks with a 32-word transmit FIFO each
(`FSL_FEATURE_SAI_FIFO_COUNTn = 32` in the MCUX feature header already
downloaded for the port [D]) and a fractional audio PLL (PLL4), so 44.1
and 48 kHz are exact. The Teensy Audio library's `output_i2s.cpp` [S2] is
a working reference for SAI1 and shows everything a driver must do:

* Audio PLL: `24 MHz * (c0 + c1/c2)`, kept between 648 and 1296 MHz. For
  44.1 kHz its formula gives 24 MHz * 28.2240 = 677.376 MHz, then SAI1
  pre-divider 4 and divider 15, giving MCLK = 11.2896 MHz = 256 fs [D].
  For 48 kHz: 28.672, dividers 4 and 14, MCLK = 12.288 MHz [D].
* Clock root: `CCM_CSCMR1` SAI1 select = PLL4; `CCM_CS1CDR` pre-divider
  and divider; MCLK pin direction in `IOMUXC_GPR_GPR1`.
* Transmitter: `TCR2` bit clock divider (`DIV(1)`, MCLK/4 = 64 fs), master
  bit clock; `TCR4` frame of 2 words, 32-bit sync width, frame sync
  master; `TCR5` 32-bit words; `TCR1` watermark (it uses 28).
* Data: eDMA triggered by `DMAMUX_SOURCE_SAI1_TX`, half/complete
  interrupts refill the buffer.

Two ways to feed the FIFO:

| Method | Interrupt rate at 44.1 kHz stereo | Notes |
|--|--|--|
| FIFO request interrupt, watermark 16 | about 5500 /s [D] (16 of 88200 words/s) | simplest; fine for bring-up; underrun shows as the FIFO error flag |
| eDMA, two blocks of 256 frames | about 172 /s [D] | what the Teensy library does; needs an eDMA driver, a DMA-safe buffer and cache care on the M7 |

The SD driver in the tree avoids DMA today, so interrupt mode first and
eDMA second is the low-risk order. Hamnix Micro leaves the core at the boot ROM
clock; the audio PLL is separate from the core PLL, so audio clocking does
not depend on raising the core clock, but the decode budget does (2.4).
i.MX RT117x has the same SAI block with a different clock tree; not
studied.

### 1.4 Buffers, latency, underrun

One MP3 frame is 1152 samples: 26.1 ms at 44.1 kHz, 4608 bytes as 16-bit
stereo. The decoder produces audio in those bursts, so the ring must hold
more than one frame plus whatever stall has to be survived.

| Item | Proposed size | Time at 44.1 kHz | RAM |
|--|--|--|--|
| DMA block (two of them) | 256 stereo frames | 5.8 ms each | 2 x 1 KB |
| Ring, nRF52840 | 4096 frames | 93 ms | 16 KB |
| Ring, Teensy 4.1 | 16384 frames | 372 ms | 64 KB |

* Block size sets the interrupt deadline and rate. With double buffering
  the driver has one full block period (5.8 ms) to supply the next
  pointer, far longer than any interrupt latency the kernel should have,
  and 172 wake-ups per second, which matters once idle is tickless.
* Ring size sets how long the decoder may be late: time spent preempted,
  a slow SD read, a file-system operation. It is also the added latency,
  which is irrelevant for file playback and too long for interactive
  sound; a later low-latency mode can shrink the ring by a control message.
* nRF52840 specific: the file system is on internal flash. Internal flash
  page erase stalls the CPU for tens of milliseconds (figure quoted from
  memory, not re-checked). DMA keeps running during the stall but only the
  current and the already-latched block are safe, about 6 to 12 ms.
  Either no flash erase while audio plays, or partial erase, or larger
  blocks. This needs a decision before the driver is written.
* Underrun policy: the interrupt handler fills the missing part of a block
  with zeros, counts the event, and keeps the clocks running. It never
  blocks and never stops the peripheral on underrun.
* Start threshold: the driver starts the clocks only when the ring is half
  full, and stops them (and releases HFXO on the nRF52840) after the ring
  has been empty for a set time or on close after drain.

RAM is the constraint on the nRF52840, where the shell alone uses 104 KB
of data. Playback needs about 50 KB (decoder process about 30 KB, ring
16 KB, blocks 2 KB); check that against what is left beside a shell.

### 1.5 Where the decoder runs

In an unprivileged process, not in the kernel.

* A decoder parses untrusted files. MPU isolation is exactly the
  protection wanted; a decoder bug then ends one process with exit code
  139 and nothing else.
* It is C code under third_party; a process can already be a C program
  (`user/progs/crel.c`), and system calls may block, so `write` on a full
  ring is the natural pacing.
* The kernel side needs no thread. The interrupt handler copies at most
  1 KB from the ring into the next block and wakes a blocked writer when
  the ring falls below half. Waking at a low-water mark rather than per
  block batches the decoder's work and keeps wake-ups low.
* Priority: the decoder process above the shell and other interactive
  programs, below anything with a hard deadline (console line discipline,
  future radio work). With a 93 ms ring, the sum of all higher-priority
  run time inside any 93 ms window must stay below the ring's slack. The
  decoder must be given a floating-point context (minimp3 is
  single-precision float; the trap path already handles FP frames).
* Stack: minimp3 keeps about 16 KB of scratch on the stack (2.3). The
  process loader must be able to give one program a 20 KB stack.

### 1.6 `/dev/audio` and `/dev/audioctl`

Devices already live under `/dev`, and the system-call set follows Plan 9
habits, so two files in that style:

* `/dev/audio`: write-only for now. `write` accepts s16le stereo frames,
  blocks while the ring is full, returns a short count only on a signal
  or close. One opener at a time (`-EBUSY` for a second); no mixer.
* `/dev/audioctl`: text. Writes: `rate 44100`, `chans 2` (mono is
  duplicated by the driver), `vol 0..100` (a shift/multiply in the copy;
  the MAX98357A has no volume control of its own), `drain`, `flush`.
  Read returns one line each: requested and actual rate, ring size and
  fill, minimum fill since open, underrun count, blocks played. These
  counters are the debug aid for build-and-test without a reviewer.

No new system call is needed: the ring is kernel memory and data crosses
by copy in `write`, checked by `uaccess` like any other buffer.

### 1.7 External DAC and amplifier parts (examples only)

None of these is chosen; the "parts must be orderable" rule applies before
any goes on a board.

| Part | What it is | MCLK | Notes |
|--|--|--|--|
| MAX98357A | mono class-D amplifier with I2S input, drives a speaker directly | not needed [S3] | 8 to 96 kHz, 2.5 to 5.5 V, 16/24/32-bit I2S [S3]; about 3 W into 4 ohm at 5 V per listings quoting the datasheet; channel select and gain by pin strapping; no I2C |
| PCM5102A | stereo line-out DAC, 2.1 V RMS ground-centred | not needed: internal PLL derives it from BCK [S4] | 8 to 384 kHz, 3.3 V, TI status ACTIVE [S4]; needs a headphone or speaker amplifier after it; accepted BCK/LRCK ratios not re-checked |
| UDA1334A | stereo DAC with PLL locked to WS | not needed in audio mode [S5] | 16 to 100 kHz in two PLL ranges [S5]; old part, lifecycle not confirmed, check before use |

All three work from SCK/LRCK/SDOUT alone, which suits the nRF52840: MCK
need not be routed, and a DAC that locks to the bit clock tolerates the
off-nominal rates. Whether each accepts 32 bit clocks per frame is
unchecked (section 5). A MAX98357A breakout serves for the first test.

## 2. Software MP3 decode: is it feasible?

### 2.1 Published figures

"MHz" means the clock at which the decoder would use the whole CPU;
divide by the real clock for load. All are for stereo.

| Decoder | Platform | Stream | Figure | Tag, source |
|--|--|--|--|--|
| Helix fixed-point | ARM7TDMI, ARMulator, zero-wait memory | 44.1 kHz 128 kbps | 26 MHz | [S] [S6] |
| Helix | ARM9TDMI / ARM920T / ARM9E, StrongARM, XScale (same set-up) | 44.1 kHz 128 kbps | 21 / 24 / 17, 17, 17 MHz | [S] [S6] |
| Helix | ARM7TDMI ... XScale (same set-up) | 48 kHz 320 kbps | 30 / 24 / 27 / 20 / 20 / 20 MHz | [S] [S6] |
| Helix | AT91SAM7S256 (ARM7TDMI) at 54 MHz, code in flash | low bit rate | 16 ms per frame, i.e. about 61 % or 33 MHz [D] | [M] [S7] |
| Helix (Teensy codec library) | Teensy 3.x, Cortex-M4 | up to 320 kbps | "with only 48 MHz" | [C] [S8] |
| Helix | RP2040, Cortex-M0+ | 320 kbps | "without issues", no figures | [C] [S9] |
| minimp3, float | STM32F411, Cortex-M4F at 100 MHz | 128 kbps | about 30 % load, i.e. about 30 MHz | [M] one forum user [S10] |
| minimp3, float | same poster's estimate | 320 kbps | "maybe about 70M" | estimate by the poster, not measured [S10] |
| minimp3, float | RP2040 (no FPU) | any | "too slowly to practically use" | [C] [S9] |
| libmad (Rockbox build) | Sansa Clip v2, ARM9E at 40 MHz | LAME 128 kbps | 26.35 MHz | [M] [S11] |
| OpenCore pvmp3, fixed-point | ESP32-S3 (LX7) at 240 MHz | 48 kHz 128 / 320 kbps | 13.1x / 10.6x real time, i.e. about 18 / 23 MHz [D] | [M] [S12] |
| OpenCore pvmp3 | ESP32 (LX6) at 240 MHz | 48 kHz 128 kbps | 3.2x real time, about 75 MHz [D] | [M] [S12] |
| minimp3 | Intel i7-6700K | conformance vectors | 1.5 to 2.8 million clock ticks per second of audio | [M] [S13]; x86 with SSE, says nothing about Cortex-M |

Not found: any figure for an nRF52840 or a Cortex-M7, any ARM figure in
minimp3's own tables, any Teensy codec library load measurement.

### 2.2 What this means for the nRF52840 (Cortex-M4F, 64 MHz)

All of the following are extrapolations [E]; none is a measurement on the
target.

| Decoder | 128 kbps, 44.1 kHz | 320 kbps | Basis |
|--|--|--|--|
| Helix fixed-point | 27 to 41 % (17 to 26 MHz) | 31 to 47 % (20 to 30 MHz) | ARM9E and ARM7TDMI simulator figures taken as bounds for a Cortex-M4; consistent with the Teensy "48 MHz" claim |
| libmad | about 41 % (26 MHz) | no figure | ARM9E measurement in Rockbox's tuned build; upstream libmad on Thumb-2 may differ |
| minimp3 float | about 47 % (30 MHz) | about 110 % (70 MHz): **not real time** | one user's F411 measurement scaled linearly by clock; the 320 kbps input is itself that user's guess |

Reading: MP3 at ordinary bit rates looks feasible on the nRF52840 with
any of the three, at a third to a half of the CPU; minimp3 at 320 kbps is
doubtful. The sources disagree enough that the first hardware task is to
measure milliseconds per frame on the real chip (cycle counter around
the decode call). If it is too slow: mono or lower-bit-rate files (the
speaker does not justify 320 kbps), or a fixed-point decoder (section 3).

### 2.3 RAM and ROM

| Decoder | Static tables (ROM) | Code | Per-instance RAM | Tag, source |
|--|--|--|--|--|
| Helix | 13446 bytes | 20744 bytes (ARM, ADS) | 23816 bytes heap; no writable globals; excludes input and PCM buffers | published [S6] |
| Helix (Adafruit wrapper) | "about 32 KB of flash" together | | "about 32 KB of RAM" | [C] [S14] |
| minimp3 | in the code figure | "30 kb" binary, x86 [S13]; Thumb-2 size unknown | `mp3dec_t` 6668 bytes, plus about 16.2 KB scratch on the stack during a frame, total about 23 KB | [D] from the struct definitions in `minimp3.h`; not measured |
| libmad | not counted | not counted | about 30 KB: `sbsample` 9216, overlap 4608, `samples` 9216, `filter` 4096, main data 2567, plus stack | [D] from `frame.h`, `synth.h`, `stream.h` |
| OpenCore pvmp3 | no figure | no figure | about 21.3 KB state, 1.5 KB input, 4.5 KB PCM | [M] by the port's author [S12] |

Add to any of them: one PCM frame buffer (4608 bytes) and an input buffer
(a 320 kbps frame is at most 1441 bytes; 4 KB is enough to decode, and
minimp3-based players commonly use 16 KB for reliable resync). minimp3
needs only `memcpy`, `memmove` and `memset` from libc and no allocator
(checked in the header).

### 2.4 Cortex-M7 (Teensy 4.1)

No published Cortex-M7 MP3 figure was found. By extrapolation [E] from the
Cortex-M4 numbers, with no credit for the M7's better per-MHz performance,
30 to 70 MHz of work is 5 to 12 % of a 600 MHz core. Even the heaviest
case is easy. The open point is the clock Hamnix Micro actually runs at: the
core is left at whatever the boot ROM set, and if that is far below
600 MHz the margin shrinks in proportion. The boot banner reports the
measured clock; that number decides whether the clock set-up must come
before audio. The M7 has a double-precision FPU; minimp3 uses single
precision only, so the same build serves both chips.

## 3. Candidate decoders and licences

The project is AGPL-3.0-or-later. "Combinable" below means the code can
be linked into, or shipped as part of, an AGPL-3.0-or-later firmware
image. The FSF's licence list [S15] is the reference for the compatibility
statements; this is not legal advice.

| Decoder | Format | Licence (as read from the upstream files) | Combinable? | Technical notes |
|--|--|--|--|--|
| minimp3 | MP3, also layers I/II | CC0-1.0 [S13] | Yes. FSF: CC0 is GPL-compatible; it grants no patent licence, which matters little now (3.2) | single header, float, passes ISO conformance on all vectors per its README, no allocator |
| dr_mp3 | MP3 | public domain (Unlicense) or MIT-0, by choice; states it is based on minimp3 [S16] | Yes | minimp3's core plus a pull-style API, seeking and its own chunk buffers; larger, no gain for a streaming process |
| PDMP3 | MP3 layer III | public domain / Unlicense [S17] | Yes | thesis reference code: `pow()`, `sin()`, `cos()` in double precision at run time, static float work arrays, `malloc`; not designed for speed. Not suitable |
| libmad | MP3, layers I/II | GPL-2.0-or-later (`COPYRIGHT` says "version 2 ... or (at your option) any later version") [S18] | Yes: taken under GPL-3.0, and AGPL-3.0 section 13 permits combining with GPL-3.0 code; that part stays under the GPL. Plain GPL-2.0-only would not be combinable | 32-bit fixed-point, 24-bit output, mature; upstream dormant since 2004; ARM assembly multiply option |
| Helix MP3 | MP3 | RPSL 1.0, or RCSL for those who have signed it with RealNetworks [S6] | **No** (3.1) | best published figures for small ARM; widely used in hobby projects regardless |
| OpenCore pvmp3 | MP3 | Apache-2.0 (as stated by the esphome port [S12]; upstream file headers not read) | Yes: FSF lists Apache-2.0 as GPLv3-compatible | fixed-point; not in the brief, found during research; the fallback if float is too slow |
| stb_vorbis | Ogg Vorbis | public domain (Unlicense) or MIT [S19] | Yes | float; Vorbis needs per-stream codebooks and large windows, so RAM is well above MP3's; no figure verified. Rockbox's Tremor: 20.16 MHz on ARM9E at 128 kbps [M] [S11] |
| libopus | Opus | BSD-3-Clause plus patent grants; fixed-point build via `FIXED_POINT` [S20] | Yes | ESP32-S3 at 240 MHz, 48 kHz stereo music: 6.6x real time float, 5.8x fixed [M] [S21], i.e. about 36 to 41 MHz [D]; that port uses 80 to 150 KB state and a 120 KB pseudo-stack. Too heavy for the nRF52840 as packaged there |
| libFLAC | FLAC | BSD-3-Clause for the libraries (`COPYING.Xiph`) [S22] | Yes | integer only; Rockbox's own decoder: 7.1 to 7.7 MHz on ARM9E [M] [S11]. Cheap to decode, large files |
| dr_flac | FLAC | public domain (Unlicense) or MIT-0 [S16] | Yes | single header; block buffer RAM depends on the file's block size |
| WAV PCM, IMA ADPCM | uncompressed, 4:1 | own code | n/a | no third-party code; 176 KB/s for CD-quality PCM, which the small flash file system cannot hold for long, and the SD card can |

### 3.1 Helix: what the licence text says

Read from `RPSL.txt` in a mirror of the Helix source [S6]:

* Section 4.1: a derivative work that contains covered code must "be
  licensed as a whole ... under the terms of this License and no other
  license except as provided in Section 4.2".
* Section 4.2 exempts independently developed modules only if they are
  "wholly subject to one of the Compatible Source Licenses" in Exhibit B,
  while "all Covered Code must be subject to the terms of this License".
* Exhibit B (dated October 2002) lists the GPL and LGPL with a footnote
  warning that their reciprocal terms may prohibit the combination, and
  that applying "non RPSL license terms, including without limitation the
  GPL, to Covered Code is expressly forbidden". The AGPL is not listed.
* Section 11 ends the licence on patent action against the licensor;
  section 12.5(b) ends it if local law prevents compliance.

The AGPL requires the whole combined work to be under the AGPL; the RPSL
requires its part to stay under the RPSL only. Both cannot hold for one
linked image. The FSF lists the RPSL as a free but GPL-incompatible
licence for this reason and for its choice-of-venue clause [S15]. The
RCSL is a separate agreement with RealNetworks and is not an open
licence. Conclusion: Helix, and wrappers around it such as Adafruit_MP3
and the Teensy codec library's MP3 part, cannot go into Hamnix Micro. Whether a
separately loaded Helix program on the file system would count as mere
aggregation is a legal question this note does not rely on.

### 3.2 MP3 patents

Fraunhofer IIS states that the MP3 licensing programme of Technicolor and
Fraunhofer "has been terminated" on 23 April 2017 [S23]. The statement
does not itself say the patents expired; press coverage does (the last
US ones in 2017). No patent licence is believed necessary today.

### 3.3 Recommendation

First implementation: **WAV (PCM) playback, then minimp3**.

* WAV needs no decoder and proves the driver, the ring and `/dev/audio`
  in isolation.
* minimp3's licence is the simplest possible fit. It is one unmodified
  header for `third_party/minimp3/` with `LICENSE` and `UPSTREAM`, plus a
  three-line C file of ours that defines `MINIMP3_IMPLEMENTATION`.
* It is single-precision float, which both targets execute in hardware,
  needs no allocator, and its state is the smallest of the candidates.
* It ships conformance vectors with reference output, which the staged
  plan uses.

Known risk: CPU cost on the nRF52840 (about half the CPU at 128 kbps by
extrapolation, possibly not real time at 320 kbps). If measurement
confirms it: first constrain the files (bit rate, mono), then switch to
a fixed-point decoder with a compatible licence, OpenCore pvmp3 or
libmad, after measuring both. Helix is excluded on licence. FLAC
(dr_flac) is the sensible second format for the SD-card target; Vorbis
and Opus are not worth their RAM on the nRF52840.

## 4. Staged plan

| Stage | Build | Test without hardware | Needs hardware |
|--|--|--|--|
| 0 | Host harness: the minimp3 wrapper compiled for the host, decoding the upstream vectors and a few ordinary files to raw PCM | compare with the upstream reference PCM and with a second decoder on the host; accept a difference of 1 LSB (float rounding), not a hash | no |
| 1 | Kernel ring, `/dev/audio`, `/dev/audioctl`, and a **fake sink** driver: a timer-paced consumer that takes 256 frames per 5.8 ms and writes them to a file or debug channel as WAV | in QEMU/Renode: a process writes a known sine and a ramp; the dumped WAV must match byte for byte; blocking, short writes, close-with-drain, forced underrun (pause the writer) and the counters | no |
| 2 | WAV player program (header parse, `rate`/`chans` to ctl, copy loop) | plays into the fake sink; output equals the file's data chunk | no |
| 3 | minimp3 as a C process, 20 KB stack, FP context | in the emulator for both targets: decode the vectors from the file system into the fake sink; compare with stage 0 output within 1 LSB; check the stack high-water mark; instruction counts per frame as a rough cost only (emulators are not cycle-accurate) | no |
| 4 | nRF52840 I2S driver behind the same driver interface | register-level unit test of the rate table against the table in 1.2; emulator support for the I2S peripheral is unknown | Feather nRF52840 Express, I2S amplifier breakout: sine tone, LRCK measured, `TXPTRUPD` on a pin, deliberate late pointer to learn the underrun behaviour, flash erase during playback |
| 5 | MP3 on the nRF52840 | | milliseconds per frame by cycle counter at 64, 128, 192, 320 kbps; minimum ring fill; decide on fallbacks from the numbers |
| 6 | RT1062 SAI driver, interrupt mode, audio PLL | PLL and divider arithmetic checked by script against 1.3 | Teensy 4.1 with the same breakout; then eDMA |
| 7 | Later: volume ramp on start/stop, software resampler or 24-bit mode for the nRF52840 pitch error, FLAC, a mixer, capture | | |

Stages 0 to 3 give a tested playback path with no hardware. The driver
interface (start, stop, set rate returning the actual rate, next-block
callback) is fixed at stage 1, so all three sinks are interchangeable.

## 5. Open questions and what was NOT verified

* Decisions wanted: accept off-pitch playback on the nRF52840 at first;
  the nRF52840 RAM budget with a shell running; flash erase during
  playback; which DAC or amplifier goes on the board.
* **No CPU figure in this note was measured on an nRF52840 or an RT1062.**
  The nRF52840 loads in 2.2 and the Cortex-M7 loads in 2.4 are
  extrapolations.
* The minimp3 Cortex-M figure rests on one forum post by one user [S10];
  compiler, flags and file are unknown. Its 320 kbps number is a guess.
* Helix figures are from an ARM simulator with ideal memory, 2003 [S6].
  The Teensy codec library publishes no load figures; its "48 MHz" line
  is a claim. Frank Boesing's forum measurements were not found.
* Could not be fetched: the Rockbox wiki codec table (its numbers here
  come from the author's forum post [S11]), the MPlayer list thread,
  Silicon Labs AN1112 and Microchip AN1367 (Helix on EFM32 and PIC32),
  and the MAX98357A product page (its facts are from search summaries).
* minimp3 and libmad RAM figures are sums of struct fields read from the
  headers, not linker-map or run-time measurements. minimp3's Thumb-2
  code size is unknown.
* nRF52840: behaviour when `TXD.PTR` is not updated (repeat of the last
  block is hearsay); accuracy of HFCLK without the crystal; duration of
  the CPU stall on internal flash erase; I2S errata for the chip revision
  on the board; whether the emulator models I2S. None checked.
* DACs: accepted bit-clock-per-frame ratios (32 fs for the nRF52840 in
  16-bit mode, 48 fs in 24-bit mode) for all three parts; MAX98357A
  output power; UDA1334A lifecycle; stock for any of them.
* RT1062: the Teensy library code was read through a summarising fetch,
  `set_audioClock()` itself was not seen; register use must be redone
  from the reference manual. The actual boot ROM core clock is not known
  to this note. eDMA with the data cache on the M7 not studied. RT117x
  not studied.
* OpenCore pvmp3's Apache-2.0 licence is taken from the esphome
  component page, not from the upstream source files. Opus and FLAC
  figures are from other architectures (Xtensa, ARM9E).
* stb_vorbis and libopus RAM needs on Cortex-M: no figure verified.
* Whether a file-system-loaded C program with a 20 KB stack and
  floating point works today.

## 6. Sources

Fetched 2026-11-27. Downloaded copies used for [D] figures are in
`/var/tmp/hackerslide-agent/dl-audio-research/` (untrusted data).

* [S1] Nordic, nRF52840 Product Specification, I2S chapter: https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/i2s.html
* [S2] PJRC Teensy Audio library, `output_i2s.cpp`: https://github.com/PaulStoffregen/Audio/blob/master/output_i2s.cpp
* [S3] Analog Devices MAX98357A: https://www.analog.com/en/products/max98357a.html
* [S4] Texas Instruments PCM5102A: https://www.ti.com/product/PCM5102A
* [S5] NXP/Philips UDA1334ATS data sheet (mirror): https://www.farnell.com/datasheets/809141.pdf
* [S6] Helix fixed-point MP3 decoder, `docs/cpuusage.xls`, `docs/memory.xls`, `RPSL.txt`, `LICENSE.txt` (mirror): https://github.com/ultraembedded/libhelix-mp3
* [S7] mikrocontroller.net, ARM MP3/AAC Player: https://www.mikrocontroller.net/articles/ARM_MP3/AAC_Player
* [S8] Frank Boesing, Arduino-Teensy-Codec-lib README: https://github.com/FrankBoesing/Arduino-Teensy-Codec-lib
* [S9] minimp3 issue 110 (RP2040 reports): https://github.com/lieff/minimp3/issues/110
* [S10] ST community thread, post by AScha.3: https://community.st.com/others-hardware-and-software-57/optimizing-throughput-for-high-fidelity-320kbps-mp3-decoding-on-stm32-systems-167570
* [S11] Hydrogenaudio, "Codec performance comparison", posts by saratoga: https://hydrogenaudio.org/index.php?msg=713455
* [S12] esphome micro-mp3 (OpenCore fork), README and decode benchmark: https://components.espressif.com/components/esphome/micro-mp3/versions/0.4.0/examples/decode_benchmark
* [S13] minimp3 README, `minimp3.h`, `LICENSE`: https://github.com/lieff/minimp3
* [S14] Adafruit, Native MP3 decoding on Arduino: https://learn.adafruit.com/native-mp3-decoding-on-arduino/overview
* [S15] FSF licence list (RPSL, CC0, Unlicense, Modified BSD, Expat, Apache-2.0, AGPLv3 entries): https://www.gnu.org/licenses/license-list.en.html
* [S16] dr_libs, `dr_mp3.h` and `dr_flac.h`: https://github.com/mackron/dr_libs
* [S17] PDMP3, README and `pdmp3.c`: https://github.com/technosaurus/PDMP3
* [S18] libmad `README`, `COPYRIGHT`, headers (mirror): https://github.com/markjeee/libmad
* [S19] stb_vorbis: https://github.com/nothings/stb/blob/master/stb_vorbis.c
* [S20] libopus `COPYING` and `README`: https://github.com/xiph/opus
* [S21] esphome micro-opus decode benchmark: https://components.espressif.com/components/esphome/micro-opus/versions/0.4.0/examples/decode_benchmark
* [S22] FLAC `COPYING.Xiph` and README: https://github.com/xiph/flac
* [S23] Fraunhofer IIS, mp3: https://www.iis.fraunhofer.de/en/ff/amm/consumer-electronics/mp3.html
