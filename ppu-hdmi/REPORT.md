# PPU capture → HDMI integration (Tang Nano 20K / GW2AR-18)

**Status: RTL complete, simulation-verified (219,694 checks, 0 errors), built for the target
device with timing CLOSED (0 violations in every clock domain). Nothing was run on hardware.**
No board was attached, nothing was programmed, no picture was observed. See §7 for the exact
UNVERIFIED list.

**Project directory: `ppu-hdmi/`.** The two parent projects (`hdmi-core/`,
`ppu-capture/`) are untouched — see §8.

> ### 720p60 变体 / 720p60 variant — 见 **[`720P60_REPORT.md`](720P60_REPORT.md)**
>
> 本工程现在有两个格式变体，共用同一条采集通路：
> This project now carries two format variants sharing one capture path:
>
> | | 1080p30（本文件 / this file） | 720p60（`720P60_REPORT.md`） |
> |---|---|---|
> | 光栅 / raster | 2200×1125 (VIC 16) | 1650×750 (VIC 4) |
> | 垂直 / vertical | 4×（960 行，上下黑边 60 px） | **3×**（720 行，黑边 0） |
> | 扫描线 / scanlines | 4 相 100/100/50/0 | **3 相 亮/半/暗 256/128/0** |
> | 水平 4:3 / H 4:3 | 1280 = 整数 5× | **960 = 整数 3× + 768→960 ×1.25 锐利双线性** |
> | 水平 1:1 / H 1:1 | 1024 = 4× | 1024 = 4× |
> | 像素时钟 / pixel clock | 74.25 MHz | 74.25 MHz（**同一套 rPLL/CLKDIV**） |
> | 工程 / project | `ppu_hdmi.gprj` | `ppu_hdmi_720p60.gprj` |
> | 状态 / status | 仿真 219,694 检查 PASS；构建 0 违例；**未上板** | 仿真 190,659 检查 PASS；构建 0 违例（Fmax 94.564 MHz）；**未上板** |
>
> 两个变体的 RTL 是**两套**，不是参数开关：`ppu_video_pipeline.v`（1080p30）**逐字节未改**，
> 所以本文件 §4/§5 的仿真与时序/资源指纹继续有效（已在 V1.9.12 上逐项复现，见
> `720P60_REPORT.md` §5.5）。
> The two variants use **two** RTL modules, not one parameterised module:
> `ppu_video_pipeline.v` (1080p30) is **byte-identical to before**, so the simulation and
> timing/resource signatures in §4/§5 here stay valid (reproduced item for item on V1.9.12 —
> see `720P60_REPORT.md` §5.5).

**Revision note (v2).** Two things changed after the first build and the first simulation run:
1. the TMDS encoder is pipelined by one stage to close the 42 ps setup violation (§5.2),
2. the 4:3 mode is **1280** wide (exactly 5x), not 1170. **The 1170 figure came from a bad
   spec in the original task brief** (1170/960 = 1.219, which is not 4:3). Do not change it
   back — see §2.2.

---

## 1. What was built

```
 2C02 EXT0..3 ─┐
 VOUT slicers ─┼─> ppu_capture_intercept ──> 6-bit palette entry ─┐
 CPU $2006/07 ─┘   (verbatim from ppu-capture)                  │
                                                                  v
                                        ┌──────────────────────────────────┐
                                        │ ppu_framebuffer 256x240x6 (BSRAM)│
                                        │  write: PPU dot clock            │
                                        │  read : 74.25 MHz pixel clock    │
                                        └──────────────┬───────────────────┘
                                                       v
                             ppu_video_pipeline: Bresenham H scaler (4x / 5x)
                               + 4x vertical + scanline shading + nes_palette
                                                       v
                              hdmi_timing (CEA-861) + tmds_encoder x3 (pipelined)
                                                       v
                                       OSER10 x4 + ELVDS_OBUF -> HDMI
```

| File | Origin | Description |
|---|---|---|
| `rtl/ppu_hdmi_top.v` | **new** | Integrated top: rPLL/CLKDIV, capture path, video pipeline, TMDS, HDMI pins. |
| `rtl/ppu_video_pipeline.v` | **new** | hdmi_timing instance, horizontal Bresenham accumulator, vertical 4x + scanline phase, framebuffer, palette, border, 2-clock `de`/`hsync`/`vsync` alignment. |
| `rtl/ppu_framebuffer.v` | **new** | 61440×6 semi-dual-port memory (separate read/write clocks). |
| `rtl/nes_palette.v` | **new** | 64×24-bit 2C02 → RGB table (nestang values, GPL-3.0, reuse approved). |
| `rtl/tmds_encoder.v` | copy of `hdmi-core/rtl/tmds_encoder.v` + **one added pipeline stage** | Functionally identical (proved by simulation, §5.2); the parent's file is unchanged. |
| `rtl/hdmi_timing.v`, `rtl/pll_hdmi_371.v` | verbatim copy from `hdmi-core/rtl/` | Byte-identical (hash-checked). |
| `rtl/ppu_write_guard.v`, `ppu_injector.v`, `ppu_palette_shadow.v`, `ppu_ext_capture.v`, `ppu_pixel_out.v`, `ppu_capture_intercept.v` | verbatim copy from `ppu-capture/rtl/` | Byte-identical (hash-checked). |
| `tb/tb_ppu_hdmi.v` | **new** | Self-checking testbench (both scaler modes in parallel, golden model). |
| `tb/tb_tmds_pipe_equiv.v`, `tb/tmds_encoder_ref.v` | **new** | Proves the pipelined encoder emits the same stream as the original (1 clock later). |
| `sim/run.ps1`, `sim/simulation_output.txt`, `sim/tmds_pipe_equivalence.txt` | **new** | Icarus run scripts + the actual console output quoted in §4/§5.2. |
| `constraints/tn20k_ppu.cst`, `constraints/ppu_hdmi.sdc` | **new** | Board pins + clock constraints. PPU-side pins deliberately unassigned (§5.4). |
| `ppu_hdmi.gprj`, `scripts/build.ps1`, `scripts/build.tcl` | **new** | Gowin project + ASCII-scratch build wrapper (same workaround as the parent). |
| `bitstreams/ppu_hdmi_1080p30.fs` | build output | **Timing-clean bitstream — but no hardware verification.** |
| `reports/…` | build output | `build_final.log`, `pnr_report.txt`, `timing_paths.txt`, `timing_summary.html`, `pinout.html`. |

**720p60 变体新增的文件 / files added for the 720p60 variant**（详见
[`720P60_REPORT.md`](720P60_REPORT.md)）：

| File | Origin | Description |
|---|---|---|
| `rtl/ppu_video_pipeline_720p.v` | **new** | 720p60 缩放：3× 垂直 + 3 相扫描线 + 水平 4:3（3× 整数 + 768→960 锐利双线性）/ 1:1（4×）。4 拍流水线。 |
| `rtl/ppu_hdmi_top_720p60.v` | **new** | 720p60 顶层：与 `ppu_hdmi_top.v` 只差光栅常数与流水线实例；rPLL/CLKDIV/TMDS 完全相同。 |
| `ppu_hdmi_720p60.gprj` | **new** | 720p60 工程（同器件、同 `.cst`，另一份 `.sdc`）。 |
| `constraints/ppu_hdmi_720p60.sdc` | **new** | 四个时钟数值与 `ppu_hdmi.sdc` **相同**（720p60 像素时钟也是 74.25 MHz）。 |
| `tb/tb_ppu_hdmi_720p.v` | **new** | 720p60 自检 testbench（两种模式并行）。 |
| `sim/run_720p.ps1`, `sim/simulation_output_720p.txt` | **new** | 720p60 仿真脚本 + 真实控制台输出。 |

The reused files are **copies**, not links, because the Gowin build wrapper mirrors `rtl/` and
`constraints/` into an ASCII scratch directory and builds there with purely relative paths
(§6). The upstream copies in `hdmi-core/` and `ppu-capture/` remain authoritative.

### Data path

```
capture_en = 1:   CPU $2000 writes reach the PPU with bit 6 (EXT output) forced to 1
capture_en = 1:   $2006/$2007 writes shadow 32x6 palette RAM
pixel_valid = ~blank: framebuffer write pointer advances, one 6-bit entry per active pixel
                      pointer is reset by the PPU-side vsync rising edge
video domain:     cx,cy -> border / picture decision -> Bresenham sx + (cy-60)/4 sy + phase
                  framebuffer[sy*256+sx] -> nes_palette -> scanline attenuation -> rgb
```

---

## 2. Design decisions worth knowing

### 2.1 Framebuffer
256 × 240 × 6 bits = **368,640 bits = 45 KiB**. One buffer, two clock domains, one read
register. Gowin maps it to **25 of 46 BSRAM blocks (55 % of 828 kbit)** — the raw payload is
44 % of the BSRAM bits, the extra is block-granularity overhead (the tool used deep 16K×1
mode, 4 blocks per data bit, 6 bits wide).

**The write port is a linear pointer, not an x/y dot counter.** It advances on `pixel_valid`
and resets on the PPU-side vsync. This is exact for a 2C02 that delivers 256 active pixels
per line × 240 lines (61,440 writes/frame), which is what the simulation drives and what the
PPU does. A source with a different active-line length would skew the image; adding a dot
counter derived from `hsync` is the fix if that ever matters. Documented, not hidden.

Single buffering means a visible tear is possible if the read side passes the write pointer
during a frame. That is accepted per the brief ("single buffer") and is not simulated.

### 2.2 Horizontal scaler — both modes are now pure integer repeat
```
mode 1:1  H_OUT = 1024  = 256 × 4   -> 4x horizontal  (4x/4x overall)
mode 4:3  H_OUT = 1280  = 256 × 5   -> 5x horizontal  (5x/4x overall, 1280x960 = exactly 4:3)
```
Both are exact integer ratios, so nearest-neighbour repeat is exact in both modes: no
interpolation, no fractional phase, no resampling artefacts.

They are still produced by **one** Bresenham accumulator (`acc += 256; if (acc >= H_OUT)
{ acc -= H_OUT; sx++ }`), which degenerates to a fixed carry cadence at these ratios (carry
every 4th / every 5th column). It costs three flops and keeps a single code path for both
modes and for any future ratio, so it was kept rather than special-cased.

**Geometry (proved in simulation, not just arithmetic):**

| | H_OUT | H_START | side bars | V_START | top/bottom bars |
|---|---:|---:|---:|---:|---:|
| 1:1 (4x) | 1024 | **448** | 448 px each side | 60 | 60 px |
| 4:3 (5x) | 1280 | **320** | 320 px each side | 60 | 60 px |

> **The original brief's "~1170" for the 4:3 width was wrong and has been corrected to 1280.**
> 1170/960 = 1.219:1, not 4:3; 960 × 4/3 = 1280 exactly. The simulation caught nothing here —
> 1170 was faithfully implemented and verified as specified. This is a spec error, not an RTL
> bug, and 1280 is now the default in `H_OUT_43`.

### 2.3 Vertical + scanlines
Fixed 4x line repeat: `sy = (cy - 60) / 4`, `phase = (cy - 60) mod 4`. Brightness per phase is
**parameterised**: `LVL0..LVL3` in 1/256 units, defaults `256, 256, 128, 0`
(100 % / 100 % / 50 % / 0 %). Each level is a constant-coefficient multiply that folds to a
shift at elaboration, then a 4-way mux — no hardware multiplier.

### 2.4 RGB
`nes_palette.v` is the 64-entry 2C02 table from nestang (`src/nes2hdmi.v`, GPL-3.0, reuse
approved). Emphasis and greyscale are captured by `ppu_palette_shadow` but **not applied** —
that would be a further stage.

### 2.5 Mode select is a build-time parameter, not a switch
`ppu_hdmi_top #(.H_MODE_4_3(0))`. A physical switch would need one verified board pin; none
was invented. The pipeline's `h_mode_43` is a real input port, so wiring a switch later is a
one-line top-level change once a pin is known.

### 2.6 The 720p60 variant, and why it is a second module
Full detail in [`720P60_REPORT.md`](720P60_REPORT.md); the three decisions worth recording here:

1. **Separate module, not a parameter.** `ppu_video_pipeline_720p.v` exists so that
   `ppu_video_pipeline.v` stays byte-identical and this file's §4/§5 results keep their
   meaning. The 720p60 variant changes the vertical factor (4→3), the scanline phase count
   (4→3), and turns horizontal 4:3 from an integer 5× into a fractional 1.25× — a different
   structure, not a different constant.
2. **4:3 at 720p cannot be an integer scale.** 960/256 = 3.75, so it is built as the brief
   specifies: an integer **3×** stage A (256→768, every source pixel exactly 3 samples,
   uniform) followed by a **768→960 (×1.25)** "sharp bilinear" stage B that takes the left
   sample when `frac(4i/5) < 0.2`, the right sample when `> 0.8`, and interpolates otherwise.
   Because stage-A neighbours are the *same* source pixel whenever `j mod 3 ≠ 2`, the blend is
   visible on only **256 of the 960 columns** (one per source-column boundary); the other
   **704 = 73.3 %** are exact single-pixel repeats. **The brief's "~90 % sharp" is not
   reachable on this quantised 5-phase lattice** — the honest measured figure is 73.3 %, and
   the thresholds cannot change it (they only move which of the five phases blend). All
   thresholds and weights are `parameter`s.
3. **One read port, two taps.** The framebuffer is semi-dual-port and a second copy would not
   fit (2 × 25 > 46 BSRAM). The address sequence is monotone, so the left tap is recovered
   with a conditional latch (`hsrc`) instead of a second port — see the module header.

---

## 3. Simulation setup

Tool: **Icarus Verilog 12.0**, plain Verilog-2001 (`-g2005`), `C:\iverilog\bin\`.
Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run.ps1`

Two phases, both clock domains, two pipelines side by side:

* **Phase 1 — capture.** Program all 32 palette entries through the CPU register bus
  (`$2006`/`$2007`), then drive **three complete NTSC-shaped source frames**: 341 dots × 262
  lines, 256×240 active, with a known pattern on EXT0–3 + EXT4 and comparator-shaped
  `blank_i`/`vsync_i`. Then **read out and check all 61,440 framebuffer entries** through a
  hierarchical reference (`u_vid_1x.u_fb.mem[n]`) — the whole capture path, palette lookup
  and write-pointer addressing, exhaustively.
* **Phase 2 — read-out.** One complete **2200×1125 1080p30 frame** at 13.468 ns/pixel
  (74.25 MHz). Two `ppu_video_pipeline` instances (4x and 5x) are fed the same write stream
  and read out in the same frame.

Checks per sampled output pixel:
1. **exact source address** `u_vid_1x.raddr` / `u_vid_43.raddr` vs `sy*256+sx` computed by
   *direct division* in the testbench (not the DUT's accumulator — an independent algorithm);
2. **scanline phase** vs `(cy-60) mod 4`;
3. **RGB** vs an independently transcribed palette table + the same attenuation rule.

Sampling: **full 1920-column sweeps on 23 rows** (0, 59–65, 120, 300, 539–543, 700, 900,
1016–1020, 1079 — picture top edge, centre, bottom edge, border) plus **4 columns on every
one of the 1080 rows**, for both modes. Plus 24 named points.

Simulated time: 83 ms (50 ms capture + 33 ms read-out), ~2.5 M video pixel clocks,
wall-clock ≈ 145 s. VCD is off by default (it would be enormous); `run.ps1 -Vcd` enables it.

A third, separate testbench (`tb_tmds_pipe_equiv.v`) checks the encoder change — §5.2.

---

## 4. Simulation results — actual console output

`sim/simulation_output.txt`, reproduced verbatim:

```text
================================================================
 PPU capture -> framebuffer -> scaler -> HDMI  integration test
 PPU dot clock 186.24 ns (5.369 MHz), video clock 13.468 ns (74.25 MHz)
 1080p30 raster 2200x1125; picture 1024x960 (1:1, 4x) / 1280x960 (4:3, 5x)
================================================================

=== PHASE 1: program palette shadow via $2006/$2007 ===
  wrote 32 palette entries ($3F00-$3F1F)
  driving 3 source frames: 341x262 dots, 256x240 active, EXT pattern
  checking framebuffer contents (256 x 240 entries, both instances) ...
  framebuffer: 61440 entries checked (1:1 and 4:3 instances)

=== PHASE 2: read out one 2200x1125 (1080p30) video frame ===

---- 1:1 mode: 4x exact, 256 -> 1024, h_start 448, v_start 60 ----
    PASS  border left      px(200,540) src(0,0) ph0  rgb 303030
    PASS  border top       px(960,20) src(0,0) ph0  rgb 303030
    PASS  picture TL       px(448,60) src(0,0) ph0  rgb 087c00
    PASS  4x repeat col 3  px(451,60) src(0,0) ph0  rgb 087c00
    PASS  4x repeat col 4  px(452,60) src(1,0) ph0  rgb 3032ec
    PASS  centre pixel     px(960,540) src(128,120) ph0  rgb 00323c
    PASS  picture BR       px(1471,1019) src(255,239) ph3  rgb 000000
    PASS  scanline ph1     px(960,61) src(128,0) ph1  rgb 00323c
    PASS  scanline ph2 50% px(960,62) src(128,0) ph2  rgb 00191e
    PASS  scanline ph3  0% px(960,63) src(128,0) ph3  rgb 000000
    PASS  next line ph0    px(960,64) src(128,1) ph0  rgb 00323c
    PASS  picture TR       px(1471,60) src(255,0) ph0  rgb 006678
    PASS  border right     px(1472,60) src(0,0) ph0  rgb 303030

---- 4:3 mode: 5x exact, 256 -> 1280, h_start 320, v_start 60 ----
    PASS  border left      px(100,540) src(0,0) ph0  rgb 303030
    PASS  picture TL       px(320,60) src(0,0) ph0  rgb 087c00
    PASS  centre pixel     px(960,540) src(128,120) ph0  rgb 00323c
    PASS  picture BR       px(1599,1019) src(255,239) ph3  rgb 000000
    PASS  scanline ph2 50% px(960,62) src(128,0) ph2  rgb 00191e
    PASS  5x col 1000      px(1000,60) src(136,0) ph0  rgb 00323c
    PASS  5x col 700       px(700,60) src(76,0) ph0  rgb 087c00
    PASS  border before TL px(319,60) src(0,0) ph0  rgb 303030
    PASS  5x repeat col 5  px(324,60) src(0,0) ph0  rgb 087c00
    PASS  5x repeat col 6  px(325,60) src(1,0) ph0  rgb 3032ec
    PASS  border after BR  px(1600,60) src(0,0) ph0  rgb 303030

================================================================
 framebuffer entry checks : 61440
 swept pixel checks       : 96790
 named point checks       : 24
 total checks             : 219694
 errors                   : 0
 RESULT: PASS
================================================================
```

### What the individual results mean

| Observation | Meaning |
|---|---|
| 1:1 `border left (200,540)`, `border top (960,20)`, `border right (1472,60)` = `303030` | Picture is inset with `0x303030`; 1472 is exactly one column past the 1024-wide picture. |
| 1:1 `picture TL (448,60) src(0,0)` | First picture pixel = source (0,0) at the computed origin 448/60. |
| 1:1 `col 3 (451) src(0,0)` vs `col 4 (452) src(1,0)` | Exact 4x: columns 448–451 all read source column 0; 452 reads source column 1. |
| 1:1 `centre (960,540) src(128,120)` | 960 = 448+512 → 512/4 = 128; 540 = 60+480 → 480/4 = 120. |
| 1:1 `BR (1471,1019) src(255,239)` | 1471 = 448+1023, 1019 = 60+959 → last source pixel. |
| `scanline ph1/ph2/ph3` at (960,61/62/63) | Same source pixel (128,0) at 100 % / **50 %** (0x32→0x19, 0x3c→0x1e — exact halving) / **0 %**. 100/100/50/0 lands on the right rows. |
| `next line ph0 (960,64) src(128,1)` | Phase wraps after 4 rows and the source line advances by exactly 1. |
| 4:3 `picture TL (320,60)`, `border before TL (319,60)`, `border after BR (1600,60)` | The picture occupies exactly [320, 1600): 320 px pillarbox each side. |
| 4:3 `repeat col 5 (324) src(0,0)` vs `repeat col 6 (325) src(1,0)` | Exact 5x: 320–324 are five repeats of source column 0, 325 starts source column 1. **No fractional scaling anywhere.** |
| 4:3 `centre (960,540) src(128,120)`, `BR (1599,1019) src(255,239)` | 960 = 320+640 → 640/5 = 128; 1599 = 320+1279 → last column. |
| 4:3 `col 1000 → src 136`, `col 700 → src 76` | (1000−320)/5 = 136, (700−320)/5 = 76. Exact integer division. |
| 96,790 swept checks, 0 errors | Every sampled column of every sampled row matches the golden model for **both** modes, including the fetch address (a wrong-but-same-coloured source pixel would still be caught). |
| 61,440 framebuffer entries × 2 instances, 0 errors | The complete capture path — EXT bits, palette shadow, palette lookup, write pointer, 256×240 ordering — is correct for a full frame. |

**Not covered by this simulation:** the OSER10 serialisers, the rPLL/CLKDIV (Gowin
primitives, outside the video pipeline), the analog VOUT slicers, the tri-state bus
transceivers, and any real 2C02 behaviour (see `ppu-capture/REPORT.md` §6). The TMDS encoder
is covered by its own equivalence testbench (§5.2), not by this one.

---

## 5. Gowin build — timing CLOSED

Tool **Gowin V1.9.11.03 Education x64** (explicit `gowinRoot`, no `.lic` needed), device
`GW2AR-18C` / `GW2AR-LV18QN88C8/I7` / version C.

> **已用授权的 V1.9.12 复现 / reproduced on the licensed V1.9.12.** 加入 720p60 变体之后，
> 用 `C:\Gowin\Gowin_V1.9.12_x64`（许可证在 `IDE\bin\gwlicense.ini`）在同一组选项下
> 重编 `ppu_hdmi.gprj`：退出码 0、`.fs` 7,264,150 字节（MD5 `8DB3DBFC…`）、
> Logic/Register/CLS/BSRAM = **656/217/390/25**、`clkpix` Fmax **120.564 MHz**、
> 最差 setup **+5.174 ns**（`u_enc0/d_r_4_s0` → `u_enc0/acc_5_s0`，8.259 ns）、
> 0 setup / 0 hold 违例 —— 与下面 §5.1/§5.2 逐项相同。说明本变体是纯增量的：
> 1080p30 的综合与布局布线结果可逐项复现，不是"看起来没坏"。
> After adding the 720p60 variant, `ppu_hdmi.gprj` was rebuilt with the licensed
> `C:\Gowin\Gowin_V1.9.12_x64` (licence in `IDE\bin\gwlicense.ini`) under the same options:
> exit 0, `.fs` 7,264,150 bytes (MD5 `8DB3DBFC…`), Logic/Register/CLS/BSRAM =
> **656/217/390/25**, `clkpix` Fmax **120.564 MHz**, worst setup **+5.174 ns**
> (`u_enc0/d_r_4_s0` → `u_enc0/acc_5_s0`, 8.259 ns), 0 setup / 0 hold violations — item for
> item the same as §5.1/§5.2 below. So the variant is purely additive: the 1080p30
> synthesis and place-and-route results reproduce exactly.

```powershell
cd ppu-hdmi
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 `
    -Task all -PlaceOption 1 -RouteOption 2 -TimingDriven 1 -GlobalFreq 74.25 -CorrectHold 0 -Replicate 1
```

Exit code **0**, bitstream produced: `impl/pnr/ppu_hdmi.fs`, 7,264,154 bytes (copied to
`bitstreams/ppu_hdmi_1080p30.fs`).

### 5.1 Resources (real numbers from the P&R report)

| Resource | Usage | Available | % |
|---|---:|---:|---:|
| Logic | 656 | 20,736 | 4 % |
| Register | 217 | 15,750 | 2 % |
| CLS | 390 | 10,368 | 4 % |
| **BSRAM** | **25** | **46** | **55 %** |
| I/O Port | 49 | 66 | 75 % |
| IOLOGIC | 8 | 121 | 7 % |
| rPLL | 1 | 2 | 50 % |
| CLKDIV | 1 | 8 | 13 % |

The brief's estimate (≈45 KB, ≈44 % of the 828 kbit BSRAM) is right for the **data payload**
(368,640 / 828,000 = 44.5 %), but the tool reports **25 of 46 blocks = 55 %** because 6-bit
words cannot fill 18 kbit blocks exactly. Fabric cost of everything else is negligible.
(Registers went 189 → 217 and Logic 626 → 656 when the encoder gained its pipeline stage.)

### 5.2 Timing — all domains clean

| Clock | Constraint | Actual Fmax | Violations |
|---|---|---|---|
| `clkpix` (pixel) | 74.250 MHz / 13.468 ns | **120.564 MHz** | **0** (TNS 0.000) |
| `clk27` (oscillator) | 27.000 MHz | 221.862 MHz | 0 |
| `ppupix` (2C02 dot clk) | 5.369 MHz / 186.24 ns | 93.970 MHz | 0 |
| `clk5` (serialiser) | 371.25 MHz | *"No timing paths to get frequency of clk5"* | n/a — **expected, not a green light** |

| | before (v1) | after (v2) |
|---|---:|---:|
| worst setup slack `clkpix` | **−0.042 ns** (1 endpoint, TNS −0.042) | **+5.174 ns** (0 endpoints, TNS 0.000) |
| worst hold slack (all clocks) | +0.329 ns | **+0.328 ns**, 0 violations |
| `clkpix` Fmax | 74.021 MHz | **120.564 MHz** |
| logic levels on the critical path | 17 | **12** |
| critical path | `rgb_2_s13` → `u_enc1/acc_5` | `u_enc0/d_r_4_s0/Q` → `u_enc0/acc_5_s0/D`, 8.259 ns |
| 2nd worst path | (same net) | `u_timing/cy_2_s0` → `u_fb/…/ADB[8]`, 8.215 ns, slack +5.219 ns |

**How the 42 ps was closed — the encoder pipeline stage.** Stage 1 of `tmds_encoder` (`n1d`
popcount, `xnor_mode`) is now registered, together with `d`/`de`/`c0`/`c1`; stage 2 keeps
computing `qm`, the popcounts, `qout` and `acc_add` combinationally. That splits
`d → acc` into ~4 + ~8 levels instead of 17, and the critical path moved off the encoder
entirely (the new worst path is the framebuffer read-address adder, with 5.2 ns to spare).

This is a **pure pipeline change, stream-identical**:
* the accumulator trajectory is the same, one clock edge later
  (`acc(k+2) = acc(k+1) + add(d(k), acc(k+1))` where the original had `acc(k+1) = acc(k) + add(d(k), acc(k))`);
* `de`/`c0`/`c1` are delayed by the same clock, so data symbols, control symbols and the
  running-disparity state all shift together — the emitted 10-bit stream is the original
  stream delayed by one `clk_pixel`. The TMDS link is self-clocked (the receiver recovers the
  pixel clock from the clock lane), so a uniform one-pixel latency is invisible.
* **Proved by simulation**, not just argued: `tb/tb_tmds_pipe_equiv.v` instantiates the
  pipelined encoder and `tb/tmds_encoder_ref.v` (a verbatim copy of the unpipelined parent
  module) side by side, drives identical stimulus, delays the reference's output by one clock
  and compares every cycle:

```text
==================================================================
 TMDS encoder equivalence: pipelined vs original (1-clock offset)
==================================================================

  cycles compared : 200000
  mismatches      : 0
 RESULT: PASS  (pipelined stream == original stream, 1 clk later)
==================================================================
```
  Stimulus covers all 256 data values repeatedly during `de=1`, all four `{c1,c0}` control
  codes during `de=0` (which also resets the running disparity), and a pseudo-random phase.
  Full log: `sim/tmds_pipe_equivalence.txt`.

Effort sweep that got here (all measured, not guessed) — for the record, with the *unpipelined*
encoder, since that is what the option sweep applies to:

| place / route / timing_driven | Fmax | TNS | endpoints |
|---|---|---:|---:|
| 0 / 0 / 0 (tool defaults) | 68.325 MHz | −1.168 ns | 11 |
| 1 / 2 / 1 | 74.021 MHz | −0.042 ns | 1 |
| 3 / 4 / 1 | 69.998 MHz | −4.773 ns | 10 |

An earlier attempt to close the gap purely in RTL *without* pipelining — rewriting the
encoder's 8-deep `qm` ripple as an equivalent flat prefix-XOR — was proved functionally
identical but made the logic **deeper** (17 → 18 levels, Fmax 67.902 MHz), so it was
discarded in favour of the pipeline stage.

### 5.3 Three real build obstacles found (all fixed, all reusable)

1. **73 ports > 53 regular I/Os.** The GW2AR-LV18QN88 package has only 53 regular I/Os
   (`ERROR (PA2024)`). The first top exposed `cpu_d_in`/`cpu_d_out`/`cpu_d_oe` and the same on
   the PPU side plus two observation ports. Both register buses are now **bidirectional
   8-bit buses** (`inout`, which is what the hardware is), and the captured pixel stream is
   not exported → **49 I/Os**.
2. **`BANK_VCCIO` defaults to 1.8 V** for ports that have no `IO_PORT` line, which conflicts
   with the board's 3.3 V banks and fails P&R
   (`WARN (PR2042) BankVccio '1.8' ... conflicts`, then
   `ERROR (PR0003): Failed to place with '20 IOBUF(s) unPlaced`). Fixed by declaring
   `IO_PORT … BANK_VCCIO=3.3` for every PPU-side port. Note `DRIVE=` is **illegal on
   input-only ports** (`ERROR (CT1108)`).
3. **The `.cst` must be written without a UTF-8 BOM** — a BOM makes the constraint parser fail
   with `ERROR (CT2000) 'syntax error' near token '?'` at line 1.

### 5.4 Pin assignment — board pins fixed, PPU-side deliberately unassigned

Board pins are the hardware-verified ones from the parent project: `sys_clk` **4**, TMDS clock
**33/34**, TMDS data **35/36, 37/38, 39/40** (all `LVCMOS33D`), LEDs **15/16**.

**The PPU-side ports have electrical attributes (`IO_TYPE`, `PULL_MODE`, `BANK_VCCIO`) but no
`IO_LOC`.** There is no interposer board yet — it will be hand-wired perfboard — so the pins
are chosen later. Gowin auto-places them for now; the placement it picked is *not* usable on a
real board (it landed on configuration/JTAG-adjacent pins), so **every PPU-side `IO_LOC` must
be supplied before this is built for hardware.** The complete port list is in §9.

### 5.5 Warnings that are benign, and why

| Warning | Count | Assessment |
|---|---|---|
| `WARN (EX3791)` size truncation, `ppu_video_pipeline.v:190/193/204/210` | 4 | Reviewed by hand: max values are `acc+256 ≤ 1536` (13-bit), `cy_off>>2 ≤ 239` (9-bit), `sy*256+sx ≤ 61439` (16-bit). No bits are actually lost. (The 720p60 module has **zero** `EX3791` — its products are declared at their true width.) |
| `WARN (NL0002) … swept in optimizing` for `nes_palette`, `ppu_pixel_out` | 2 | Post-flattening notice (the module name disappears into the parent's logic). The palette output is present in the netlist — the simulation proves the colours come out, and the same warning appears in the hardware-verified parent build. |
| `WARN (CV0016) Input hsync_i is unused` | 1 | True: the linear write pointer only needs `vsync`. `hsync_i` is still wired through `ppu_ext_capture` (its output is unused). |
| `WARN (TA1117) Can't calculate clocks' relationship between ppupix and clk27` | 2 | Expected — they are asynchronous. The only real crossing is the dual-clock BSRAM write/read port, which needs no timing relationship. |
| `WARN (PR1014) Generic routing … 'sys_clk_d'` | 1 | Pre-existing in the parent project (27 MHz oscillator into the rPLL). |
| `alog error: failed to open log file …sh.log` | 1 | Harmless `gw_sh` stderr noise, present on every run. |
| **Zero** `EX0205 / EX0206 / EX0210 / EX0214 / PA1019 / TA1123` | 0 | **No invalid PLL parameter substitution and no clock-frequency mismatch.** The 371.25 MHz rPLL configuration was accepted as written. |

---

## 6. Toolchain notes (this workspace)

* **Non-ASCII path.** This workspace lives under `…\OneDrive\文档\…`; `gw_sh` mangles it to
  `??` and dies with `ERROR (SP0002): Corrupted project file`. `scripts/build.ps1` mirrors
  `rtl/` + `constraints/` + the `.gprj` into an ASCII `%TEMP%` directory, builds there, and
  copies `impl/` back. Same approach as the parent project.
* **Execution policy is Restricted and `pwsh` is not installed** — run scripts as
  `powershell -NoProfile -ExecutionPolicy Bypass -File …`.
* Icarus scripts also mirror to `%TEMP%` for the same reason.
* Programming, if the bitstream is ever flashed: `programmer_cli` device string **`GW2AR-18C`**.
* **Two `.gprj` variants share one `rtl/`.** Only the files listed inside each `.gprj` are
  compiled, so the 1080p30 project never sees `ppu_video_pipeline_720p.v` /
  `ppu_hdmi_top_720p60.v` and vice versa. `build.ps1` mirrors *all* `*.gprj` and uses a
  per-project `%TEMP%` scratch dir (`ppu_hdmi_build_<stem>`), and merges (not wipes) `impl/`,
  so building one variant does not destroy the other's reports.
* **Rebuild commands / 重建命令:**
  ```powershell
  # 1080p30
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 `
      -Project ppu_hdmi.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64 `
      -Task all -PlaceOption 1 -RouteOption 2 -TimingDriven 1 `
      -GlobalFreq 74.25 -CorrectHold 0 -Replicate 1
  # 720p60
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 `
      -Project ppu_hdmi_720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64 `
      -Task all -PlaceOption 1 -RouteOption 2 -TimingDriven 1 `
      -GlobalFreq 74.25 -CorrectHold 0 -Replicate 1
  # 仿真 / simulations
  powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run.ps1        # 1080p30
  powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_720p.ps1   # 720p60
  ```
* **Encoding rules (learned the hard way, still enforced):** `*.cst` / `*.sdc` UTF-8 **without**
  BOM (a BOM → `ERROR (CT2000) 'syntax error' near token '?'`); `*.ps1` UTF-8 **with** BOM
  (otherwise the host PowerShell decodes as ANSI and the Chinese comments become mojibake);
  `*.v` / `*.tcl` without BOM. `run_720p.ps1` was written with a BOM for exactly this reason.

---

## 7. What is UNVERIFIED (explicit list)

1. **No hardware.** No board attached, nothing programmed, no TV picture, no TMDS eye/skew
   measured. `bitstreams/ppu_hdmi_1080p30.fs` is a timing-clean build artifact, not a proven
   picture.
2. **`clk5` at 371.25 MHz is not proven by STA** — it only reaches OSER10 `FCLK` pins, so STA
   has no fabric endpoints. The real limit is the PLL spec (`CLKOUT ≤ 625 MHz`); 371.25 MHz is
   41 % below. Physical OSER10/HCLK operation at that rate is unmeasured here (it is the rate
   the parent design runs at, and the parent *was* verified on a TV).
3. **The PPU-side pinout does not exist** (§5.4). Auto-placed; must be redone.
4. **`ppu_pix_clk` is assumed to be the 2C02 dot clock (5.369 MHz)**. On hardware this has to
   come from the PPU `CLK` pin (21.47727 MHz / 4) or a slicer; the exact source, phase and
   clock-capable pin are undefined. The capture path's `clk` domain is the 27 MHz oscillator
   in the top level, whereas the `ppu-capture` testbench used a 4× dot clock — the
   injector's timing assumptions are therefore **not** exercised at board level here.
5. **No clock-domain-crossing analysis** beyond "dual-clock BSRAM". `ppupix` → `clkpix` has no
   synchronisers because there is no handshake: the read side may see a torn frame.
6. **Emphasis / greyscale are captured but not applied** to the RGB output.
7. **720p60 is a separate project, not this top.** `PIC_H = 960 > 720` here, so this
   1080p30 top cannot drive a 720-line raster. The 720p60 variant is
   `ppu_hdmi_top_720p60.v` + `ppu_hdmi_720p60.gprj` (3× vertical, 3 scanline phases,
   960/1024-wide horizontal) — see [`720P60_REPORT.md`](720P60_REPORT.md). It is
   simulation-verified and timing-closed, and **also not run on hardware**. Its own
   UNVERIFIED list (including "the 73.3 % sharp column figure is a simulation/arithmetic
   result, not an observed picture") is in §8 of that file. Everything in §7 items 1–6 and
   8–11 applies to it unchanged.
8. **The framebuffer write pointer assumes 256×240 active pixels per frame** (§2.1).
9. **The TMDS encoder's stream equivalence is a simulation result** (200,000 cycles, 0
   mismatches) plus the induction argument in §5.2 — not a formal proof and not measured on
   hardware.
10. **The PLL/OSER10/ELVDS_OBUF primitives are reused as-is** from the parent project; their
    provenance is the parent's hardware run at 1080p30 and 720p60, not this build.
11. **Interlaced/odd NES frames, sprite-0 hit timing, and the analog VOUT slicers** are outside
    this work (see `ppu-capture/REPORT.md` §6 for the full capture-side list, including the
    safety warning about driving EXT0–3 while they are grounded).

---

## 8. Parent projects are untouched

`hdmi-core/` and `ppu-capture/` were not modified. Evidence:

* Newest mtime anywhere under `hdmi-core/rtl/` is **15:14**, under
  `ppu-capture/rtl/` **15:59**, and under `ppu-capture/sim/` **16:03**; the first file of
  this project was created at **17:0x**. All parent timestamps predate this project.
* Hash comparison of every file this project copies:

| File | vs parent |
|---|---|
| `hdmi_timing.v`, `pll_hdmi_371.v` | **IDENTICAL** |
| `ppu_write_guard.v`, `ppu_injector.v`, `ppu_palette_shadow.v`, `ppu_ext_capture.v`, `ppu_pixel_out.v`, `ppu_capture_intercept.v` | **IDENTICAL** |
| `tmds_encoder.v` | **DIFFERS by design** — `ppu-hdmi/rtl/` holds the pipelined variant; `hdmi-core/rtl/tmds_encoder.v` still holds the original ✓ |

The parents' own bitstreams and build reports are likewise unchanged.

---

## 9. PPU-side port list (for the perfboard pinout)

All of these are in `ppu_hdmi_top` and currently have **no `IO_LOC`**. Direction is from the
FPGA's point of view. `BANK_VCCIO=3.3` and `PULL_MODE` are already set in
`constraints/tn20k_ppu.cst`; only the pin numbers are missing.

| Port | Dir | Width | Notes for wiring |
|---|---|---:|---|
| `ppu_pix_clk` | in | 1 | **Must be a clock-capable pin.** 5.369 MHz = 2C02 CLK (21.47727 MHz) ÷ 4; needs a real clock network. `PULL_MODE=NONE`. |
| `rst_n` | in | 1 | Active-low. `PULL_MODE=UP`. |
| `cpu_d[7:0]` | **inout** | 8 | CPU-side data bus (motherboard side). Bidirectional; FPGA drives only during a CPU read (`cpu_d_oe`). Needs a 5 V-tolerant level shifter/transceiver. `PULL_MODE=UP`. |
| `cpu_cs_n` | in | 1 | CPU-side `/CS` (already decoded to $2000–$3FFF). |
| `cpu_rw` | in | 1 | 1 = read, 0 = write. |
| `cpu_a[2:0]` | in | 3 | CPU-side register address. |
| `ppu_d[7:0]` | **inout** | 8 | PPU-side (2C02 socket) data bus. Bidirectional; FPGA drives during guarded writes and injections. |
| `ppu_cs_n` | out | 1 | To the 2C02 `/CS`. |
| `ppu_rw` | out | 1 | To the 2C02 R/W. |
| `ppu_a[2:0]` | out | 3 | To the 2C02 A0–A2. |
| `ext_i[3:0]` | in | 4 | 2C02 EXT0–EXT3. **Must be isolated from ground before output mode is enabled** — see the safety warning in `ppu-capture/REPORT.md`. |
| `ext4_bg_sprite_i` | in | 1 | Comparator-derived fifth palette-address bit (1 = sprite, 0 = BG). Analog slicer required. |
| `hsync_i` | in | 1 | Comparator-derived. **Currently unused by the RTL** (the write pointer only needs vsync) but kept on the port list; tie low if unpopulated. |
| `vsync_i` | in | 1 | Comparator-derived; resets the framebuffer write pointer. |
| `blank_i` | in | 1 | Comparator-derived blanking; gates `pixel_valid`, i.e. what gets written to the framebuffer. |
| `capture_en` | in | 1 | 0 = transparent pass-through, 1 = force `$2000[6]=1` and capture. Give it a switch/strap; default off during bring-up. |
| `inject_req` | in | 1 | One-shot `$2000` injection request. `PULL_MODE=DOWN`; leave open if unused. |

Board-side ports already assigned in the `.cst`: `sys_clk` (4), `tmds_clk_p/n` (33/34),
`tmds_d_p/n[2:0]` (35/36, 37/38, 39/40), `led[1:0]` (15/16).

---

## 10. Next step on hardware

Timing is closed, so the remaining work is board-level:

1. **Define the interposer pinout** from §9 and add `IO_LOC` for every PPU-side port; re-check
   with `gowin_check` for duplicate pins and dedicated-pin misuse. Prefer a clock-capable pin
   for `ppu_pix_clk`.
2. **Prove the video path standalone first.** The lowest-risk bring-up is to feed the
   framebuffer write port from a *built-in* test pattern (a counter) instead of the PPU, tie
   `H_MODE_4_3` per build, and confirm on a TV that you get the 1024×960 (or 1280×960) picture
   with 448 (320) px side bars, 60 px top/bottom bars, and the 100/100/50/0 scanline pattern.
   That exercises everything in §1 except the capture path and needs no NES.
   **For the 720p60 variant the expected picture is 960×720 (4:3, 160 px side bars, *no*
   top/bottom bars) or 1024×720 (1:1, 128 px side bars) with 100/50/0 scanlines** — see
   `720P60_REPORT.md` §10.
3. **Then** connect the 2C02 through level shifters with EXT0–3 isolated, bring `capture_en` up
   last, and use the Gowin GAO (`.gao`) on `pix_index`/`pix_valid`/`vsync_i` to confirm the
   write stream before trusting the picture.
4. Only then check palette tracking against a test ROM that writes all 32 entries.

---

## 11. Licence

Project: **GPL-3.0-or-later**, inherited from the approved nestang reuse.
* `rtl/nes_palette.v` — the 64×24-bit table is from
  [nand2mario/nestang](https://github.com/nand2mario/nestang) `src/nes2hdmi.v` (GPL-3.0),
  values originally from <https://www.nesdev.org/wiki/PPU_palettes>. Reuse approved by the user.
* Reused RTL from `hdmi-core/` (written for this project family) and `ppu-capture/`
  (original, GPL-3.0-or-later) — copied verbatim except `tmds_encoder.v`, which gained one
  pipeline stage (functional equivalence proved in §5.2). Attribution retained in every header.
* The CEA-861 raster constants and the Tang Nano 20K pin numbers are facts taken from
  `nestang` (`src/hdmi2/hdmi.sv`, `src/boards/nano20k.cst`).
