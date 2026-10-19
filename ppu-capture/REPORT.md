# PPU capture interposer — RTL, simulation, and architecture report

**Status:** simulation-only. No synthesis, no board, no 2C02 hardware validation.

**Deliverable root:** `ppu-capture/`

---

## 0. Architecture verdict and the key correction

The original brief said: force "slave mode" on `$2000` bit 2 and read the
palette-index pixels from the CPU data bus D0–D7. **That is wrong in three
places.** The correct capture path is:

> **Force `$2000` bit 6 to 1 (EXT output / master mode), capture EXT0–EXT3,
> recover the missing fifth palette-address bit from VOUT with comparators,
> and reconstruct the 6-bit NES colour from a shadow copy of palette RAM
> tracked on the CPU bus.**

| Item | Wrong assumption | Correct / verified model |
|---|---|---|
| Pixel bus | CPU D0–D7 | EXT0–EXT3 (4 bits) + VOUT-derived EXT4 |
| Bits | 6-bit palette index | 4 low palette-address bits; 5th bit from VOUT |
| `$2000` bit | bit 2 | bit 6 |
| Forced value | 0 ("slave") | **1** (master/output) |
| EXT direction | always outputs | 0 = input/slave, 1 = output/master |
| Full colour | on EXT pins | palette RAM, shadowed from CPU writes |
| Analog video | resistor ladder from EXT | internal PPU DAC → VOUT (pin 21) |
| Real mods | data-bus capture | NESRGB / Hi-Def NES: EXT + CPU bus + VOUT |

Two nomenclature traps:

* `$2000[6] = 0` is **slave/input**; `$2000[6] = 1` is **master/output**.
  Forcing 0 ("slave") leaves EXT as inputs and captures nothing.
* The parameter formerly called `SLAVE_BIT` is now **`EXT_OUT_BIT`**, default 6.
  The value forced is 1.

**Safety warning (prominent):** on a stock NES, EXT0–EXT3 (pins 14–17) are
tied to ground. Driving them as outputs while still connected to ground can
short the PPU. The board **must** isolate those pins (PPU socket/interposer or
trace cut) before enabling output mode. This is a hardware requirement, not
something the simulation can enforce.

### What is implemented now

* transparent CPU→PPU register write path;
* `$2000` bit-6 forcing on every CPU `$2000` write (output mode survives);
* optional one-shot `$2000` injector;
* 32 × 6-bit palette shadow from `$2006`/`$2007`, +1/+32 increment, mirroring;
* `$2001` emphasis/grayscale capture;
* registered EXT0–EXT3 + `ext4_bg_sprite_i` capture;
* `hsync_i`/`vsync_i`/`blank_i` registered inputs;
* palette lookup to a 6-bit NES palette entry and `pixel_valid`;
* seven self-checking simulation scenarios.

**Not implemented:** 24-bit RGB LUT (optional), analog comparator, level
shifting, actual PPU/board.

---

## 1. What was built

| File | One-line description |
|---|---|
| [`rtl/ppu_write_guard.v`](rtl/ppu_write_guard.v) | Combinational CPU→PPU write path; when `capture_en=1`, forces `EXT_OUT_BIT` (default 6) to 1 on every CPU `$2000` write; keeps `ctrl_shadow`. |
| [`rtl/ppu_injector.v`](rtl/ppu_injector.v) | One-shot PPU `$2000` write master; waits for CPU idle and a safe `phi2` phase, drives one write, releases with hold time. |
| [`rtl/ppu_palette_shadow.v`](rtl/ppu_palette_shadow.v) | 32×6-bit palette RAM shadow: `$2006` two-write address latch, `$2007` writes, +1/+32 increment from `$2000[2]`, `$3F10/$14/$18/$1C` mirroring, `$2001` emphasis/grayscale capture. |
| [`rtl/ppu_ext_capture.v`](rtl/ppu_ext_capture.v) | Registers `ext_i[3:0]`, `ext4_bg_sprite_i`, `hsync_i`, `vsync_i`, `blank_i` on the PPU pixel clock. |
| [`rtl/ppu_pixel_out.v`](rtl/ppu_pixel_out.v) | Forms `{ext4, ext[3:0]}`, indexes the palette shadow, outputs a 6-bit palette entry and `pixel_valid`. |
| [`rtl/ppu_capture_intercept.v`](rtl/ppu_capture_intercept.v) | Top level: register bus muxes, read path, injection, palette shadow, EXT capture, lookup, status. |
| [`tb/tb_ppu_intercept.v`](tb/tb_ppu_intercept.v) | Seven-scenario self-checking testbench: 2C02 register model, tri-state data bus, EXT/palette model, timing and contention checks, VCD. |
| [`sim/run.ps1`](sim/run.ps1) | Copies sources to ASCII temp, compiles/runs with Icarus 12, saves logs/VCDs. Optional `-RunBit2` comparison. |
| [`sim/simulation_output_bit6.txt`](sim/simulation_output_bit6.txt) | Actual console output, primary `EXT_OUT_BIT=6` run. |
| [`sim/simulation_output_bit2.txt`](sim/simulation_output_bit2.txt) | Actual console output, legacy `EXT_OUT_BIT=2` comparison (expected failures). |
| [`sim/ppu_intercept_bit6.vcd`](sim/ppu_intercept_bit6.vcd) | GTKWave waveform for the primary run. |
| [`sim/ppu_intercept_bit2.vcd`](sim/ppu_intercept_bit2.vcd) | GTKWave waveform for the legacy comparison. |

### Data-path behaviour

```
capture_en = 0:
    PPU data  <- CPU data                       (all registers, unchanged)
    PPU bus   <- CPU /CS, R/W, A0..A2
    reads     <- PPU data returned to CPU

capture_en = 1, CPU write to $2000:
    PPU data  <- CPU data | (1 << 6)            (EXT output/master)
    shadow    <- same guarded byte

capture_en = 1, injection requested and CPU idle:
    PPU /CS=0, R/W=0, A=000, data=shadow | (1<<6)
    release after one PPU sampling edge + hold clocks

EXT path:
    ext_i[3:0] + ext4_bg_sprite_i
        -> registered on phi2
        -> palette_addr = {ext4_bg_sprite, ext_pixel}
        -> palette shadow read
        -> pixel_index[5:0] (6-bit NES colour entry)
```

`ext4_bg_sprite_i` is defined as **1 = sprite half ($3F10–$3F1F), 0 =
background half ($3F00–$3F0F)**. The exact polarity/derivation of the
comparator signal is a board-level choice and is **UNVERIFIED** against a real
PPU.

The guard is collision-free: it modifies the CPU's own `$2000` byte in the same
bus cycle. The autonomous injector is optional; it is only used when
`cpu_cs_n=1`, and the top level hands the bus back if the CPU starts an access.
That prevents electrical contention but not a lost/truncated CPU access; see §6.

---

## 2. Simulation results

Run command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run.ps1
```

Tool: Icarus Verilog 12.0 (`C:\iverilog\bin\iverilog.exe`, `vvp.exe`), plain
Verilog-2001 (`-g2005`). The `vvp` stderr version banner is omitted.

### 2.1 Primary run: `EXT_OUT_BIT=6` (documented 2C02 bit)

```text
VCD info: dumpfile ppu_intercept.vcd opened for output.
================================================================
 PPU capture interposer simulation
 EXT_OUT_BIT=6 (mask 0x40), phi2 period=186.24 ns, clk=46.56 ns
================================================================

=== SCENARIO 1: normal CPU writes pass through unchanged ===
  [PPU] t=651.84 ns  write $2000 = 0x90
    PASS  S1 $2000=0x90 reaches PPU unchanged  (got 0x90)
  [PPU] t=1210.56 ns  write $2000 = 0x00
    PASS  S1 $2000=0x00 really clears bit 7/4 (no force)  (got 0x00)
  [PPU] t=1583.04 ns  write $2000 = 0x90
    PASS  S1 $2000=0x90 restored  (got 0x90)
  [PPU] t=2141.76 ns  write $2001 = 0x1e
    PASS  S1 $2001=0x1E reaches PPU unchanged  (got 0x1e)
    PASS  S1 exactly four PPU writes observed
    PASS  S1 PPU read data returns to CPU unchanged  (got 0xa5)
    PASS  S1 CPU read output enable asserted
[SCENARIO 1] PASS

=== SCENARIO 2: FPGA injects $2000 with EXT-output bit set ===
    PASS  S2 EXT-output bit clear before injection
  [PPU] t=3259.20 ns  write $2000 = 0xd0
  [TIMING] injection: assert t=3142.80, sample t=3259.20, release t=3329.04 ns
  [TIMING]   setup=116.40 ns  hold=69.84 ns
  [INJ] expected injected byte = 0xd0, sampled = 0xd0
    PASS  S2 PPU received injected $2000 value  (got 0xd0)
    PASS  S2 EXT-output bit set in PPU $2000
    PASS  S2 data sampled on PPU bus  (got 0xd0)
    PASS  S2 injection address is $2000
    PASS  S2 injection was a PPU write cycle
    PASS  S2 exactly one injected write observed
    PASS  S2 no injection collision
[SCENARIO 2] PASS

=== SCENARIO 3: CPU clear of EXT-output bit cannot leave output mode ===
  [PPU] t=3817.92 ns  write $2000 = 0x40
    PASS  S3 CPU $2000=0x00 arrives with EXT-output bit forced  (got 0x40)
  [PPU] t=4190.40 ns  write $2000 = 0xd0
    PASS  S3 CPU $2000=0x90 preserves other bits, EXT output stays set  (got 0xd0)
  [PPU] t=4749.12 ns  write $2000 = 0x7f
    PASS  S3 CPU $2000=0x7F still cannot clear EXT-output bit  (got 0x7f)
    PASS  S3 shadow reports EXT-output bit held
    PASS  S3 three CPU writes, no extra injection
    PASS  S3 EXT-output bit survived all writes
[SCENARIO 3] PASS

=== SCENARIO 4: injection timing margin and no collision ===
  [PPU] t=5307.84 ns  write $2000 = 0x7f
  [TIMING] injection: assert t=5191.44, sample t=5307.84, release t=5377.68 ns
  [TIMING]   setup=116.40 ns  hold=69.84 ns
    PASS  S4 no CPU write during injection
    PASS  S4 no PPU data-bus contention
    PASS  S4 injector reports no collision
    PASS  S4 /CS, R/W, A0..A2 setup: measured 116.40 ns >= 20.00 ns (margin 96.40 ns)
    PASS  S4 /CS, R/W, A0..A2 hold: measured 69.84 ns >= 10.00 ns (margin 59.84 ns)
    PASS  S4 D0..D7 setup: measured 116.40 ns >= 50.00 ns (margin 66.40 ns)
    PASS  S4 D0..D7 hold: measured 69.84 ns >= 10.00 ns (margin 59.84 ns)
  [S4] measured injection window: setup=116.40 ns, hold=69.84 ns
  [S4] requirements: setup >= 20.00 ns, data setup >= 50.00 ns, hold >= 10.00 ns
[SCENARIO 4] PASS

=== SCENARIO 5: palette shadow writes, increment, mirroring ===
  [PPU] t=5866.56 ns  write $2000 = 0x40
    PASS  S5 $2000 shadow has EXT-output bit set, +1 inc  (got 0x40)
  [PPU] t=6239.04 ns  write $2006 = 0x3f
  [PPU] t=6797.76 ns  write $2006 = 0x00
  [PPU] t=7170.24 ns  write $2007 = 0x0f
  [PPU] t=7728.96 ns  write $2007 = 0x01
  [PPU] t=8101.44 ns  write $2007 = 0x21
    PASS  S5 palette[0x00] = 0x0F  (got 0x0f)
    PASS  S5 palette[0x01] = 0x01  (got 0x01)
    PASS  S5 palette[0x02] = 0x21  (got 0x21)
    PASS  S5 +1 auto-increment reached $3F03
  [PPU] t=8660.16 ns  write $2000 = 0x44
    PASS  S5 $2000 shadow has bit 2 set (+32 inc)  (got 0x44)
  [PPU] t=9032.64 ns  write $2006 = 0x3f
  [PPU] t=9591.36 ns  write $2006 = 0x00
  [PPU] t=9963.84 ns  write $2007 = 0x30
    PASS  S5 +32 write updated palette[0x00]  (got 0x30)
    PASS  S5 +32 auto-increment reached $3F20
  [PPU] t=10522.56 ns  write $2007 = 0x31
    PASS  S5 out-of-range $2007 did not modify palette[0x01]  (got 0x01)
    PASS  S5 out-of-range write still incremented to $3F40
  [PPU] t=10895.04 ns  write $2000 = 0x40
  [PPU] t=11453.76 ns  write $2006 = 0x3f
  [PPU] t=11826.24 ns  write $2006 = 0x10
  [PPU] t=12384.96 ns  write $2007 = 0x2a
    PASS  S5 $3F10 write mirrors to palette[0x00]  (got 0x2a)
    PASS  S5 palette[0x10] itself is not separately populated  (got 0x00)
  [PPU] t=12757.44 ns  write $2001 = 0xe1
    PASS  S5 $2001 emphasis bits captured  (got 0x07)
    PASS  S5 $2001 grayscale bit captured
    PASS  S5 read of $3F10 mirrors $3F00 entry  (got 0x2a)
[SCENARIO 5] PASS

=== SCENARIO 6: EXT pixel capture + palette lookup ===
  [PPU] t=13316.16 ns  write $2000 = 0x40
  [PPU] t=13688.64 ns  write $2006 = 0x3f
  [PPU] t=14247.36 ns  write $2006 = 0x05
  [PPU] t=14619.84 ns  write $2007 = 0x16
  [PPU] t=15178.56 ns  write $2006 = 0x3f
  [PPU] t=15551.04 ns  write $2006 = 0x15
  [PPU] t=16109.76 ns  write $2007 = 0x27
    PASS  S6 palette[0x05] = 0x16  (got 0x16)
    PASS  S6 palette[0x15] = 0x27  (got 0x27)
    PASS  S6 EXT4=0 -> palette addr 0x05
    PASS  S6 background pixel index = 0x16  (got 0x16)
    PASS  S6 pixel valid while blank=0
    PASS  S6 EXT4=1 -> palette addr 0x15
    PASS  S6 sprite pixel index = 0x27  (got 0x27)
    PASS  S6 EXT capture is registered (holds old pixel)  (got 0x27)
    PASS  S6 next edge captures EXT=0x2
    PASS  S6 palette[0x02] = 0x21  (got 0x21)
    PASS  S6 blank=1 deasserts pixel_valid
[SCENARIO 6] PASS

=== SCENARIO 7: $2006 ordering + mid-sequence inc change ===
  [PPU] t=17413.44 ns  write $2000 = 0x40
  [PPU] t=17785.92 ns  write $2006 = 0x3f
  [PPU] t=18344.64 ns  write $2006 = 0x00
  [PPU] t=18717.12 ns  write $2007 = 0x0a
    PASS  S7 first $3F00 write = 0x0A  (got 0x0a)
    PASS  S7 $2006 low/high ordering produced $3F01
  [PPU] t=19275.84 ns  write $2000 = 0x44
  [PPU] t=19648.32 ns  write $2007 = 0x0b
    PASS  S7 mid-sequence +32 write = 0x0B  (got 0x0b)
    PASS  S7 mid-sequence $2000 change selected +32
  [PPU] t=20207.04 ns  write $2000 = 0x40
  [PPU] t=20579.52 ns  write $2006 = 0x3f
  [PPU] t=21138.24 ns  write $2006 = 0x02
  [PPU] t=21510.72 ns  write $2007 = 0x0c
    PASS  S7 fresh $2006 pair writes 0x02  (got 0x0c)
    PASS  S7 returned to +1 increment
    PASS  S7 EXT pixel uses updated palette[0x02]  (got 0x0c)
[SCENARIO 7] PASS

================================================================
 SUMMARY: 61 checks, 0 errors
 RESULT: ALL SEVEN SCENARIOS PASS (EXT_OUT_BIT=6)
================================================================
tb_ppu_intercept.v:708: $finish called at 22589440 (1ps)
```

### 2.2 Legacy `EXT_OUT_BIT=2` comparison (`-RunBit2`)

The same testbench built with `-P tb_ppu_intercept.EXT_OUT_BIT=2` fails the
palette scenarios. This is expected and is useful evidence that bit 2 is the VRAM
increment, not the EXT direction:

```text
 EXT_OUT_BIT=2 (mask 0x04)
    FAIL  S5 $2000 shadow has EXT-output bit set, +1 inc  (got 0x04, expected 0x40)
    FAIL  S5 palette[0x01] = 0x01  (got 0x00, expected 0x01)
    FAIL  S5 palette[0x02] = 0x21  (got 0x00, expected 0x21)
    FAIL  S5 +1 auto-increment reached $3F03
    FAIL  S5 $2000 shadow has bit 2 set (+32 inc)  (got 0x04, expected 0x44)
    FAIL  S5 out-of-range $2007 did not modify palette[0x01]  (got 0x00, expected 0x01)
[SCENARIO 5] FAIL
    FAIL  S6 palette[0x02] = 0x21  (got 0x00, expected 0x21)
[SCENARIO 6] FAIL
    FAIL  S7 $2006 low/high ordering produced $3F01
    FAIL  S7 mid-sequence +32 write = 0x0B  (got 0x00, expected 0x0b)
    FAIL  S7 mid-sequence $2000 change selected +32
    FAIL  S7 returned to +1 increment
[SCENARIO 7] FAIL

 SUMMARY: 61 checks, 11 errors
 RESULT: FAIL (EXT_OUT_BIT=2)
```

Why: forcing bit 2 to 1 changes the `$2007` increment from +1 to +32, so the
palette write sequence lands at wrong addresses. This is exactly the corruption
a real 2C02 would suffer. The full log is
[`sim/simulation_output_bit2.txt`](sim/simulation_output_bit2.txt).

### 2.3 What each scenario proves — and does not prove

* **S1** proves the write guard is transparent when disabled and the read path
  returns PPU data. It does not model `$2002` side effects.
* **S2** proves the injector emits one PPU write with `/CS=0`, `R/W=0`, `A=0`
  and the shadow value with bit 6 set.
* **S3** proves every CPU `$2000` write while `capture_en=1` reaches the PPU
  with bit 6 set, so game code cannot clear it.
* **S4** proves the scheduled injection does not overlap a CPU write and
  measures setup/hold. It is not a proof that arbitrary CPU traffic can never
  collide with the autonomous injector.
* **S5** proves the palette shadow, +1/+32 increment, out-of-range ignore,
  `$3F10` mirroring, and `$2001` capture.
* **S6** proves the registered EXT path, `ext4` selection, palette lookup, and
  blanking. The comparator that produces `ext4` is not modelled.
* **S7** proves `$2006` high/low ordering and a mid-sequence `$2000` increment
  change.

The PPU model is register-level. It does not render frames, execute games, or
model VRAM/OAM timing beyond the palette address.

---

## 3. Why this is the architecture real mods use

### 3.1 Does `$2000` bit 6 make the PPU output pixels on D0–D7?

**No.** D0–D7 is the CPU register interface: `$2000`/`$2001` control bytes,
`$2002` status, `$2004` OAM, `$2007` VRAM/palette data. It is not a pixel bus
and the PPU never streams rendered pixels there.

Setting bit 6 controls the **EXT0–EXT3** pins. Even there it is **4 bits**, not
a 6-bit palette index, and the direction is **0 = input (slave), 1 = output
(master)**. The four bits are the low part of the pixel's palette address,
before the palette RAM lookup. The full 6-bit colour is the palette RAM data,
which is internal and not brought out on any external bus. Analog video is
`VOUT` pin 21.

### 3.2 What are the EXT pins, really?

The 2C02G has **four** EXT pins:

| Pin | Signal |
|---:|---|
| 14 | EXT0 |
| 15 | EXT1 |
| 16 | EXT2 |
| 17 | EXT3 |
| 21 | VOUT (analog composite) |

There are no EXT4–EXT5 pins. Pins 30–35 are not an EXT block: pin 30 is A8,
pins 31–38 are AD7–AD0, pins 25–30 are A13–A8. The four EXT pins are only pins
14–17.

EXT is a 4-bit bidirectional colour bus for chaining/mixing two PPUs:
direction is `$2000[6]` (0 slave/input, 1 master/output); in output mode it
carries the current pixel's 4-bit colour; in input mode it can replace/mix that
colour from another PPU. On a stock NES the pins are tied to ground, so they are
inputs and read as black. Driving them as outputs without isolating them can
short the PPU.

The exact bit ordering (`EXT0` LSB or MSB) and the exact four-bit definition are
**UNVERIFIED**. What is verified is that four bits cannot hold the full 5-bit
palette address; one more bit (BG vs sprite) is needed.

### 3.3 How the fifth bit and palette are recovered

* **NESRGB** (official technical description): sits between PPU and CPU data
  bus, captures CPU writes to palette RAM, "intercepts writes to the register
  controlling the operation of the Multiplexer, making EXT0-3 outputs", and
  extracts "EXT4, blanking, and sync" from VOUT with comparators. It then
  decodes the captured colour through its tracked palette and drives its own
  DAC/encoder.
* **Hi-Def NES**: "connects to the NES CPU and PPU and extracts the video data
  from the EXP pins on the PPU"; monitors the CPU bus; uses the PPU's composite
  output to distinguish sprite pixels from background pixels (the thread
  describes driving true palette colours to black/white so the analog video
  carries the missing BG/sprite bit).

Both are **EXT-pin capture + CPU-bus palette tracking + VOUT-derived fifth
bit**. Neither captures pixels from D0–D7.

### 3.4 Correct architecture in one line

**EXT capture with output-mode forcing (bit 6 = 1) + VOUT-derived EXT4/blank/
sync + palette-RAM shadow from `$2006`/`$2007`.** Option (A) is wrong. Option
(B) is the right family only with the output-mode forcing and fifth-bit/
palette caveats; "just read EXT with no register forcing" is wrong on a
standard 2C02.

---

## 4. Timing margins and assumptions

### 4.1 What public 2C02 documentation says

BTTD *NTSC 2C02 Technical Reference* (5th ed., 2004) describes the register
port: pin 1 `R/W` (0 write, 1 read), pins 2–9 `D0–D7`, pins 10–12 `A2–A0`,
pin 13 `/CS`, pin 18 `CLK` 21.477 MHz. When `/CS=0`, data is exchanged; when
`/CS=1`, D0–D7 float. The PPU uses 21.477 MHz / 4 ≈ 5.37 MHz as its minimum
timing unit, 341 clocks per scanline, 262 scanlines per NTSC frame.

It does **not** publish an AC table for the register bus: no `/CS` setup, no
`R/W` setup, no data setup/hold, and no explicitly stated sampling edge. The
values below are therefore assumptions, not vendor limits.

### 4.2 "PHI2" naming

On the NES, `PHI2` usually means the 2A03 CPU clock (≈1.789 MHz). The 2C02 has
a 21.477 MHz `CLK` input; its internal dot clock is ≈5.369 MHz. In this project
`phi2` is the **5.369 MHz PPU dot/pixel clock**, not the CPU `PHI2`. The RTL
uses it both for the injector phase and for EXT capture. No claim is made that
a real 2C02 exposes this as a pin.

### 4.3 Parameterized assumptions

| Parameter | Value | Basis |
|---|---:|---|
| PPU dot clock (`phi2`) period | 186.24 ns | 21.47727 MHz / 4 |
| FPGA `clk` period | 46.56 ns | 4× `phi2` in this TB |
| `/CS`, `R/W`, `A0–A2` setup `T_SU` | 20 ns | conservative assumption |
| `/CS`, `R/W`, `A0–A2` hold `T_H` | 10 ns | conservative assumption |
| `D0–D7` setup `T_DSU` | 50 ns | conservative assumption |
| `D0–D7` hold `T_DH` | 10 ns | conservative assumption |
| PPU sampling edge | rising `phi2` | assumption |
| Bus data | tri-state, one driver | board-level model |
| Injection launch | `phi2` high and stable for ≥1 FPGA clock | ≥ half a dot of setup to the next rising edge |
| Injection release | one FPGA clock after sampling edge is observed | ≥ one FPGA clock of hold |
| Palette mirroring | `$3F10/$14/$18/$1C` → `$3F00/$04/$08/$0C` | standard NES behaviour; assumption |
| EXT4 polarity | 1 = sprite, 0 = background | board-level choice; assumption |

### 4.4 Measured injection margins

| Check | Requirement | Measured | Margin |
|---|---:|---:|---:|
| `/CS`, `R/W`, `A0–A2` setup | 20.00 ns | 116.40 ns | **+96.40 ns** |
| `/CS`, `R/W`, `A0–A2` hold | 10.00 ns | 69.84 ns | **+59.84 ns** |
| `D0–D7` setup | 50.00 ns | 116.40 ns | **+66.40 ns** |
| `D0–D7` hold | 10.00 ns | 69.84 ns | **+59.84 ns** |

The guard path is combinational and adds no clock latency. These are
simulation numbers with ideal delays, not silicon margins: they exclude FPGA
output delay, board propagation, bus capacitance, transceiver enable skew,
clock skew, and 2C02 input capacitance.

The checker parameters are real parameters at the top of
[`tb/tb_ppu_intercept.v`](tb/tb_ppu_intercept.v); replace them with measured
values when available.

---

## 5. What was reused from nestang and license

**Reference:** [`nand2mario/nestang`](https://github.com/nand2mario/nestang),
GPL-3.0, [`src/ppu.v`](https://github.com/nand2mario/nestang/blob/master/src/ppu.v),
marked "Copyright (c) 2012-2013 Ludvig Strigeus … GPL Licensed" and derived
from fpganes.

### What was actually used

* **`$2000` register semantics** — cross-checked against `module PPU`,
  `case (ain) 0:` (`obj_patt <= din[3]`, `bg_patt <= din[4]`,
  `obj_size <= din[5]`, `vbl_enable <= din[7]`) and `module LoopyGen`
  (`ppu_incr <= din[2]`). This confirms bit 2 is VRAM increment; nestang does
  not model the EXT direction bit because it is a pure emulator.
* **PPU timing constants** — 341 clocks/scanline, 262 NTSC scanlines, ≈5.37 MHz
  dot clock, cross-checked against `ClockGen` (`cycle` 0..340,
  `vblank_end_sl=260`). No `ClockGen` code is instantiated or copied.
* **Coding style / register-write structure** — the `write && ain == 0` decode
  style and keeping a shadow of the last control byte were informed by reading
  nestang's PPU. The guard, injector, palette shadow, EXT capture, pixel
  output, and testbench are original code for this interposer.

No nestang source text is copied verbatim. The palette table and rendering
pipeline from nestang are **not** used. The RGB LUT is optional and not
implemented.

### License

Project: **GPL-3.0-or-later**, consistent with the approved nestang reuse. Every
source file carries `SPDX-License-Identifier: GPL-3.0-or-later`; files that
reference nestang carry a derivation note. Keep the project GPL-3.0 and retain
the nestang/fpganes attribution.

---

## 6. Hardware requirements, UNVERIFIED items, next steps

### 6.1 Hardware requirements (read before building)

1. **Isolate EXT0–EXT3 from the console.** On a stock NES these pins are
   grounded. Enabling output mode while they are still grounded can short the
   PPU. Use a PPU socket/interposer or cut the traces, and verify isolation
   before asserting `$2000[6]=1`.
2. **Level shifting / protection.** The 2C02 is a 5 V NMOS part; the FPGA I/O is
   not 5 V tolerant. Use a proper bidirectional level shifter/transceiver on
   D0–D7, /CS, R/W, A0–A2, EXT0–3, and the video-derived signals. Add series
   termination and ESD protection as appropriate.
3. **EXT4/blank/sync extraction from VOUT.** VOUT is analog composite
   (≈1 Vpp). The board needs comparators/AC coupling/sync separation to
   produce `ext4_bg_sprite_i`, `blank_i`, `hsync_i`, `vsync_i`. NESRGB uses
   comparators for EXT4, blanking, and sync; Hi-Def NES uses VOUT to
   distinguish BG vs sprite. The exact slicer levels and filter are
   **UNVERIFIED** here and must be tuned on a scope.
4. **Pixel clock / sampling phase.** EXT is captured on `phi2` (5.369 MHz
   nominal). The comparator signals are asynchronous; synchronize them and
   choose a sampling phase with measured setup/hold. The current one-register
   capture is deliberately simple.
5. **Palette tracking.** The shadow only knows writes it observes. It does not
   model palette reads, power-on contents, or writes performed before the FPGA
   is listening. Real mods initialize/handle this; a test ROM and real games are
   needed.
6. **No analog or HDMI output is implemented.** The design stops at a 6-bit
   palette entry + `pixel_valid`; RGB/HDMI is future work.

### 6.2 UNVERIFIED

1. No hardware validation: nothing was synthesized, placed, routed, programmed,
   or connected to a NES/Famicom.
2. `$2000[6]` polarity is source-derived, not measured: multiple sources agree
   0 = slave/input and 1 = master/output, but no logic-analyzer capture of a
   real 2C02 was made.
3. Exact EXT bit mapping (which pin is LSB/MSB; exact four-bit definition) is
   **UNVERIFIED**.
4. The comparator-derived `ext4_bg_sprite_i`, `blank_i`, `hsync_i`, `vsync_i`
   are clean digital assumptions; the analog extraction is not modeled.
5. Palette mirroring of `$3F10/$14/$18/$1C` is standard NES behaviour but is
   marked as an assumption in the RTL/report; verify on the target.
6. The 2C02 register sampling edge is assumed rising `phi2`; public sources
   found here do not state it.
7. The palette shadow's write detector assumes a bus-idle gap between CPU
   register writes. Back-to-back writes with no gap could be missed; a real
   design should use the PPU/CPU write strobe or a proper edge detector.
8. Autonomous injection is not universally collision-free: it starts only when
   `cpu_cs_n=1`, and the top level hands the bus back if the CPU starts an
   access. That prevents electrical contention but a CPU access that begins
   during an injection can be truncated/lost.
9. `ctrl_shadow` resets to `0x00`; an injection before the first observed
   `$2000` write can clear NMI/pattern-table bits.
10. No 5 V tolerance, level shifting, bus loading, clock-domain crossing, pin
    constraints, timing constraints, or Gowin synthesis was checked.
11. No 24-bit RGB LUT; only the 6-bit palette entry is produced.
12. No software/driver contract for `capture_en`, `inject_req`, or status.

### 6.3 Next steps

1. Resolve EXT direction and exact bit mapping on the target PPU with a socket
   that isolates EXT0–3. Do not drive a grounded pin.
2. Measure `/CS`, `R/W`, `A0–A2`, `D0–D7`, `CLK`, EXT0–3, and VOUT with a logic
   analyzer/scope; replace the assumed setup/hold and sampling-edge parameters.
3. Build the comparator/sync slicer for EXT4/blank/hsync/vsync and verify its
   polarity against known test patterns.
4. Verify palette tracking with a test ROM that writes all 32 entries, then with
   real games that change palettes mid-frame.
5. Prefer the guard-only mode for the first board (collision-free); add the
   injector only with arbitration or a guaranteed idle window.
6. Add Gowin constraints, synthesize, run static timing analysis, and only then
   program a board.
7. Add an optional RGB LUT/HDMI stage after the 6-bit path is proven.

---

## Appendix A — build/run notes

* Icarus: `C:\iverilog\bin\iverilog.exe`, `C:\iverilog\bin\vvp.exe`, 12.0.
* The workspace path contains non-ASCII characters, so `run.ps1` copies sources
  to `%TEMP%\ppu-intercept-sim-<id>`.
* `vvp` prints version info to stderr; harmless.
* Testbench watchdog: 700 µs.
* VCD files open directly in GTKWave.
* `-RunBit2` runs the legacy comparison and is expected to fail S5–S7.

## Appendix B — sources

**2C02 register/pin/EXT behaviour**

* BTTD, *NTSC 2C02 Technical Reference*, 5th ed. (2004):
  <https://www.nesdev.org/2C02%20technical%20reference.TXT>; copy used:
  <https://www.cnblogs.com/1bite/articles/17237080.html>.
* BreakingNESWiki, *PPU Pinout*:
  <https://github.com/emu-russia/breaks/blob/master/BreakingNESWiki_DeepL/PPU/pads.md>
  — EXT0–3 bidirectional; direction `$2000[6]` (0 slave, 1 master).
* BreakingNESWiki, *Multiplexer*:
  <https://github.com/emu-russia/breaks/blob/master/BreakingNESWiki_DeepL/PPU/mux.md>
  — 4-bit EXT in/out, 5-bit palette index, slave mode `$2000[6]=0`.
* `nes-ppu` API docs, `PPUCTRL_MSS`:
  <https://docs.rs/nes-ppu/0.2.0/nes_ppu/constant.PPUCTRL_MSS.html>
  — "0: background read from EXT; 1: color output on EXT"; warns setting the
  bit causes a short circuit on NES hardware.
* NESdev, *PPU registers*: <https://www.nesdev.org/wiki/PPU_registers> —
  `$2000` bit 2 = VRAM increment, bit 6 = master/slave / EXT direction.
* `cge_nes` bit map:
  <https://docs.rs/cge_nes/latest/src/cge_nes/ppu/registers/ppu_control.rs.html>.
* BreakingNESWiki, *RGB PPU*:
  <https://github.com/emu-russia/breaks/blob/master/BreakingNESWiki/PPU/rgb.md>
  — RP2C04-0003: pins 14–16 RED/GREEN/BLUE, pin 17 AGND, pin 21 /SYNC;
  `/SLAVE` unused in that chip.

**Real mods**

* NESRGB: <https://etim.net.au/nesrgb/> — palette-write capture, multiplexer
  register interception to make EXT0–3 outputs, EXT4/blank/sync from VOUT with
  comparators.
* Hi-Def NES archived NESdev thread:
  <https://archive.nes.science/nesdev-forums/f9/t12019.xhtml> — EXP-pin video
  extraction, CPU-bus monitoring, VOUT used to distinguish BG/sprite.

**Reference RTL / tools**

* nestang, GPL-3.0: <https://github.com/nand2mario/nestang> and
  <https://github.com/nand2mario/nestang/blob/master/src/ppu.v>.
* Icarus Verilog: <https://steveicarus.github.io/iverilog/>.
