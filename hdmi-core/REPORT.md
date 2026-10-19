# 1080p60 HDMI on Tang Nano 20K (GW2AR-18) — feasibility spike

**Verdict: 1080p60 does NOT work on this FPGA. The blocker is the rPLL, not the fabric.**
The serialiser needs a **742.5 MHz** clock; the GW2AR-18 rPLL `CLKOUT` is limited to
**625 MHz**. The pixel-clock domain itself is fine (198 MHz achieved, 148.5 MHz needed),
so the design is only ~19 % short in the one place that cannot be fixed in RTL.

---

## 1. Why the brief's arithmetic doesn't hold

The brief assumed a DDR serialiser at `148.5 × 5 / 2 = 371.25 MHz`. That factor of 5/2
is not enough bits. TMDS sends **10 bits per pixel per lane**:

```
1 pixel / 148.5 MHz  ->  10 bits / pixel  ->  1.485 Gbit/s per lane
DDR output          ->  2 bits per clock  ->  1.485e9 / 2 = 742.5 MHz serialiser clock
```

So the serial clock is **5 × pixel clock = 742.5 MHz**, not 371.25 MHz. 371.25 MHz DDR
yields only 742.5 Mbit/s — exactly half of what 1080p60 needs. 371.25 MHz is the
**720p** rate (74.25 MHz pixel × 5), which is why `nestang` runs it: nestang is a 720p
design. There is no 10-bit TMDS serialiser that avoids a 5× clock.

## 2. Hardware facts used (all verified, none invented)

| Item | Value | Source |
|---|---|---|
| Device | `GW2AR-LV18QN88C8/I7`, device_version **C**, config code `gw2ar18c-000` | `nestang_nano20k.gprj`, confirmed by P&R: `器件: GW2AR-18 / ... / version C` |
| 27 MHz oscillator | **pin 4** (`IOL7[A]`, `LPLL1_T_in`) | `nestang/src/boards/nano20k.cst`, confirmed in pin report |
| TMDS data pairs | **35/36, 37/38, 39/40** | same cst; placed as `LVCMOS33D` |
| TMDS clock pair | **33/34** | same cst; placed as `LVCMOS33D` |
| LEDs | 15, 16 (active low) | same cst |
| CEA-861 1080p60 (VIC 16) | 2200×1125 total, 1920×1080 active, H fp 88 / sync 44 / bp 148, V fp 4 / sync 5 / bp 36, 148.5 MHz | `nestang/src/hdmi2/hdmi.sv` `VIDEO_ID_CODE 16` — matches the brief and CEA-861-D |

`148.5e6 / (2200 × 1125) = 60.000 Hz` exactly.

## 3. Toolchain

- **Gowin V1.9.11.03 Education x64** (`C:\Gowin\Gowin_V1.9.11.03_Education_x64`) — this is
  what built everything below. It **does** support GW2AR-18.
- A node-locked licence exists at `C:\Users\charl\Downloads\gowin_E_28B2BD9E4ADA.lic`
  (`MODE=NODELOCK`, `TYPE=STD`, `EXP_DATE=2027-10-13`). No `.lic` is installed inside
  either Gowin directory, and none was needed — the Education edition synthesised,
  placed, routed and produced bitstreams without complaint.
- **Gowin CLI cannot handle this workspace's path.** The workspace is under
  `...\OneDrive\文档\...`; `gw_sh` encodes it as `??` and the build dies with
  `ERROR (SP0002) : Corrupted project file: ".../OneDrive/??/.../impl/gwsynthesis/*.prj"`.
  Workaround in `scripts/build.ps1`: mirror the (relative-path) sources into an ASCII
  scratch dir under `%TEMP%`, build there, copy `impl/` back. This is a tool path bug,
  not a design problem.
- Also note `gw_sh` prints `alog error: failed to open log file .../sh.log` on stderr —
  harmless, present on every run.

## 4. The 1080p60 attempt — `tn20k_hdmi1080p.gprj`

Built with `rPLL: IDIV=1 (27/2=13.5), FBDIV=54 (×55), ODIV=1 → 742.5 MHz`, and
`CLKOUTD /5 → 148.5 MHz`. Synthesis **accepts** the design and produces a bitstream,
but **rejects the PLL configuration** and silently substitutes defaults:

```
WARN (EX0205): Instance "rpll_inst" 's parameter "ODIV_SEL" value invalid, replaced by default value "8"
WARN (EX0214): Instance "rpll_inst" 's parameter "DYN_SDIV_SEL" value must be an even number from 2 to 128, replaced by default value "2"
WARN (EX0206): Instance "rpll_inst" 's parameter "DEVICE" value invalid
WARN (EX0210): Invalid VCO frequency "(FCLKIN*(FBDIV_SEL+1)*ODIV_SEL)/(IDIV_SEL+1)" ... suitable range is from 500MHz to 1250MHz
WARN (EX0210): Invalid CLKOUT frequency "FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1)" ... suitable range is from 3.90625MHz to 625MHz
WARN (PA1019): Invalid CLKOUT frequency ... suitable range is from 3.906MHz to 625MHz.
WARN (TA1123): the clock "clkpix"'s frequency does not match u_pll/rpll_inst/CLKOUTD's
```

Two independent hard limits kill it:

1. **`CLKOUT` max = 625 MHz** — 742.5 MHz is 19 % over. No `IDIV`/`FBDIV`/`ODIV`
   combination can help: with `ODIV=2` the VCO alone would have to be 1485 MHz
   (limit 1250 MHz), and `ODIV=1` is not even a legal value (min legal is 2).
2. `DYN_SDIV_SEL` must be **even**, so `CLKOUTD` can never divide by 5 anyway.

The resulting `.fs` therefore does **not** produce 1080p60 and must not be presented as
such — it is archived only as `bitstreams/1080p60_attempt_REJECTED_PLL.fs`.

### Timing of that attempt (note the trap)

| Domain | Constraint | Result |
|---|---|---|
| `clkpix` (pixel) | 148.5 MHz / 6.734 ns | Setup **+1.690 ns**, Hold **+0.424 ns**, Fmax **198.263 MHz**, 0 violations |
| `clk5` (serialiser) | 742.5 MHz / 1.347 ns | **"No timing paths to get frequency of clk5!"** — 0 endpoints |

The green timing report is **not** evidence that 742.5 MHz works. There is no fabric
logic at 742.5 MHz — the clock only feeds the `OSER10` hard macro's `FCLK` pin — so STA
has nothing to analyse and reports no violations. The limit is a **datasheet/PLL-spec**
limit, which STA cannot see. This distinction matters: "no timing violations" here is
a false negative for feasibility.

## 5. Achievable control build — `tn20k_hdmi1080p30.gprj`

To measure what the chip *can* do, the same RTL and the same 2200×1125 raster were
rebuilt with a legal clock: `rPLL IDIV=3, FBDIV=54, ODIV=2 → 371.25 MHz`, then
`CLKDIV DIV_MODE(5) → 74.25 MHz` pixel clock ⇒ **1920×1080 @ 30.000 Hz**,
742.5 Mbit/s per lane. This build is completely clean — **zero PLL warnings**.

| Domain | Constraint | Result |
|---|---|---|
| `clkpix` (pixel) | 74.25 MHz / 13.468 ns | Setup **+7.823 ns**, Hold **+0.424 ns**, Fmax **177.159 MHz**, 0 violations |
| `clk5` (serialiser) | 371.25 MHz / 2.694 ns | "No timing paths to get frequency of clk5" — 0 endpoints |

Both domains satisfy the requirement (Setup ≥ 0, Hold ≥ 0). Pixel-domain headroom is
large: 177–198 MHz achievable vs 148.5 MHz needed.

## 6. Resources

| Resource | 1080p60 attempt | 1080p30 build | Available |
|---|---|---|---|
| Logic | 116 | 116 | 20736 (<1 %) |
| Register | 77 | 77 | 15750 (<1 %) |
| CLS | 64 | 65 | 10368 (<1 %) |
| SSRAM (RAM16) / BSRAM | 0 | 0 | — |
| I/O Port | 11 | 11 | 66 (17 %) |
| IOLOGIC | 8 | 8 | 121 (7 %) |
| rPLL | 1 | 1 | 2 (50 %) |
| CLKDIV | 0 | 1 | 8 (13 %) |

Resource usage is irrelevant to the outcome — the design uses ~0.5 % of the fabric.
There is no resource pressure at all; the ceiling is purely clock rate.

## 7. Programming / hardware

`gowin_program mode=scan scanCables=true`:

```
Cost 0.65 second(s)
  退出码 48 = 没扫到下载器。
Scanning!
 Target Cable: Gowin USB Cable(FT2CH)/0/None/null@2.5MHz
Error: No Gowin devices found!
 Cost 0.05 second(s)
```

**No board is connected**, so no `sram` programming was attempted and **nothing was
verified on hardware**. No picture was observed, no signal was measured.

## 8. What the 625 MHz ceiling implies

- Max TMDS rate = 2 × 625 MHz = **1.25 Gbit/s per lane** — exactly the usual GW2AR-18
  LVDS figure. 1080p60 needs 1.485 Gbit/s.
- Max pixel clock = 625 / 5 = **125 MHz**.
- With standard 2200×1125 CEA blanking that is `125e6 / 2475000 = **50.5 Hz max**`
  for 1920×1080. So **1080p50/60 (VIC 31/16, both 148.5 MHz) are both out of reach**;
  1080p30 (74.25 MHz) is comfortably reachable and 1080p~50 Hz is theoretically at the
  very edge of the PLL range.
- The actual `OSER10` / HCLK maximum is **UNVERIFIED** — the tool constrained `clk5`
  onto `BANK4_BANK5_HCLK0` without complaint, but Gowin STA cannot check a hard-macro
  clock input, so 625 MHz is an upper bound from the PLL, not a proven serialiser rate.

## 9. Licence

Reference project `nand2mario/nestang` is **GPL-3.0**. It was used for board pin
numbers, the CEA-861 timing table and the rPLL configuration *values*. No nestang
source was copied: `tmds_encoder.v`, `hdmi_timing.v` and `pattern_gen.v` here are
written from the DVI 1.0 / CEA-861 specifications, and the rPLL primitive
instantiation is Gowin's own primitive boilerplate. Pin numbers and register values
are facts, not creative expression. If any nestang file were copied verbatim the
project would have to be GPL-3.0.

## 10. Files

```
hdmi-core/
  tn20k_hdmi1080p.gprj        1080p60 attempt (PLL rejected)
  tn20k_hdmi1080p30.gprj      1080p30 working control build
  rtl/pll_hdmi.v              742.5 MHz rPLL  (rejected)
  rtl/pll_hdmi_371.v          371.25 MHz rPLL (legal)
  rtl/hdmi_timing.v           CEA-861 2200x1125 counter
  rtl/tmds_encoder.v          TMDS 8b/10b encoder
  rtl/pattern_gen.v           8 colour bars
  rtl/top.v                   1080p60 top
  rtl/top_1080p30.v           1080p30 top (adds CLKDIV /5)
  constraints/tn20k.cst       pins
  constraints/tn20k.sdc       1080p60 clocks
  constraints/tn20k_1080p30.sdc
  scripts/build.tcl           gw_sh script
  scripts/build.ps1           ASCII-scratch build wrapper
  bitstreams/tn20k_hdmi1080p30.fs
  bitstreams/1080p60_attempt_REJECTED_PLL.fs
  reports/...                 P&R + timing reports
```

## 11. 720p60 variant (added later)

`top_720p60.v` + `tn20k_hdmi720p60.gprj` reuse the *same* clocks as the 1080p30 build
(74.25 MHz pixel, 371.25 MHz serialiser) and change only the CEA-861 raster to VIC 4
(1650x750). It builds clean with no PLL warnings. See `720P60_REPORT.md` and
`bitstreams/tn20k_hdmi720p60.fs`. `hdmi_timing.v` / `pattern_gen.v` are now parameterised,
with the 1080p values as defaults, so this build is unchanged (rebuilt and re-checked).
