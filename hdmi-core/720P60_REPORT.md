# 720p60 HDMI variant — Tang Nano 20K (GW2AR-18)

**Result: builds successfully.** `bitstreams/tn20k_hdmi720p60.fs`
(4,620,698 bytes, MD5 `B65BBF465205BD4452DC71FBF7940B81`).
Built with **Gowin V1.9.11.03 Education x64**, exit code 0, no PLL/clock warnings.

> ### ✅ 状态更新 / STATUS UPDATE — 已上板验证 / VERIFIED ON HARDWARE
>
> **本报告写于上板验证之前。此后，1080p30 与 720p60 两个码流都已烧录进 Tang Nano 20K，
> 并在真实电视机上正确稳定地显示，彩条稳定。**
> 因此本文件正文中"未在硬件上验证 / not verified on hardware"之类的表述**已被取代**，
> 仅作为成文当时的历史记录保留。当前状态表见仓库根目录的 [`README.md`](../README.md)。
>
> **This report predates the on-hardware run. Subsequent to it, both the 1080p30 and 720p60
> bitstreams were flashed to a Tang Nano 20K and displayed correctly and stably on a real TV;
> the colour bars rendered stably.** The "not verified on hardware" statements
> in the body below are therefore **superseded**; they are kept only as a historical record of
> the moment this report was written. See [`README.md`](../README.md) at the repository root
> for the current status table.

~~**Not verified on hardware** — no board was attached, so nothing here claims a picture on a TV.~~
**↑ 已被取代 / SUPERSEDED — 本变体已在真实电视机上验证，见上方状态更新。
This variant has since been verified on a real TV; see the status update above.**

---

## 1. Why this only needed a raster change (verified from the code, not assumed)

| Quantity | 1080p30 (working) | 720p60 (this build) | Same? |
|---|---|---|---|
| Pixel clock | 74.25 MHz (`371.25 / 5`) | 74.25 MHz (`74.25e6 / (1650×750) = 60.000 Hz`) | ✅ |
| TMDS bit clock (OSER10 `FCLK`) | 371.25 MHz | 74.25 × 10 bit / 2 DDR = **371.25 MHz** | ✅ |
| Lane bit rate | 742.5 Mbit/s | 742.5 Mbit/s | ✅ |
| rPLL config | `IDIV=3, FBDIV=54, ODIV=2` → 371.25 MHz | identical (module untouched) | ✅ |
| CLKDIV | `DIV_MODE(5)` → 74.25 MHz | identical | ✅ |

A TMDS lane sends **10 bits per pixel**; with a DDR output that is `pixel × 5` at the
serialiser clock. 720p60's 74.25 MHz pixel clock is *the same number* as 1080p30's, so the
serialiser rate is also the same. **The PLL config was NOT changed, and did not have to be.**

## 2. CEA-861 timings used (VIC 4)

Taken from Linux `include/uapi/linux/v4l2-dv-timings.h`, `V4L2_DV_BT_CEA_1280X720P60`
(<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux/v4l2-dv-timings.h>):
pixel clock 74.25 MHz, H front porch **110**, H sync **40**, H back porch **220**,
V front porch **5**, V sync **5**, V back porch **20**, both syncs positive, VIC 4.

→ H total 1280+110+40+220 = **1650**, V total 720+5+5+20 = **750**.

Mechanically re-derived from the actual RTL constants (counter arithmetic, same expressions
as `hdmi_timing.v`):

```
H total=1650  hsync asserted at cx 1390..1429 (w=40)
V total= 750  vsync asserted at cy  725..729  (w=5)
active = 1280 x 720 ; frame rate = 74.25e6 / (1650*750) = 60.000 Hz
```

`hsync` is asserted at `H_ACTIVE + H_FP = 1390`, i.e. 110 pixels after the end of active
video — the front-porch convention the module already used for 1080p30, so the new numbers
plug in without touching the logic.

## 3. Timing summary (74.25 MHz pixel domain)

From `impl/pnr/tn20k_hdmi720p60.timing_paths` and `..._tr_content.html`:

| Domain | Constraint | Setup slack | Hold slack | Actual Fmax | Violations |
|---|---|---|---|---|---|
| `clkpix` (pixel) | 74.25 MHz / 13.468 ns | **+8.352 ns** (worst path: `u_timing/cy_10_s0` → `u_enc1/acc_5_s0`) | **+0.424 ns** | **195.448 MHz** | 0 (TNS 0.000) |
| `clk5` (serialiser) | 371.25 MHz / 2.6936 ns | — | — | *"No timing paths to get frequency of clk5"* | n/a |
| `clk27` (oscillator) | 27 MHz / 37.037 ns | — | — | *"No timing paths"* (only drives the PLL) | n/a |

Pixel-domain headroom is comfortable: Fmax 195.4 MHz vs 74.25 MHz needed (2.6×).
For reference the unchanged 1080p30 build gives +7.823 ns / +0.424 ns / 177.159 MHz.

**The empty `clk5` row is expected and is NOT a green light.** `clk5` only reaches the
`OSER10` hard-macro `FCLK` pins, so STA has no fabric endpoints to analyse. The real
constraint on that clock is the PLL spec (`CLKOUT ≤ 625 MHz`); 371.25 MHz is 41 % below it.
Maximum pulse-width check: worst low-pulse slack 4.971 ns (1.0 ns required) on `clkpix`.

## 4. Warnings — none of them matter (and none are PLL-related)

| Warning | Count | Assessment |
|---|---|---|
| `WARN (NL0002) pattern_gen ... swept in optimizing` | 1 | **Pre-existing**, also emitted by the hardware-verified 1080p30 build (same wording, same file). Post-flattening note; the 1080p30 bars were proven on a TV. |
| `WARN (PR1014) Generic routing resource will be used to clock signal 'sys_clk_d'` | 1 | Pre-existing, identical in the 1080p30 build. About the 27 MHz oscillator net into the rPLL, not the serialiser. |
| `alog error: failed to open log file ...sh.log` | 1 | Harmless `gw_sh` stderr noise (documented in REPORT.md). |

**Zero** `EX0205 / EX0206 / EX0210 / EX0214 / PA1019 / TA1123` — i.e. no invalid-PLL-parameter
substitution and no clock-frequency mismatch. Nothing was silently replaced by a default.

Resource usage (vs the 1080p30 build): Logic **115** (was 116), Register **77** (same),
CLS **64** (was 65), IOLOGIC 8 (4× OSER10), rPLL 1/2, CLKDIV 1/8. Pinout byte-identical
(`sys_clk` 4, TMDS 33/34, 35/36, 37/38, 39/40, LEDs 15/16, all `LVCMOS33D`/`LVCMOS33`, Bank 3.3 V).

## 5. What exactly changed vs. the 1080p30 design

Added (new files):
- `rtl/top_720p60.v` — copy of `top_1080p30.v` with the raster overridden; PLL, CLKDIV,
  encoders, OSER10, ELVDS_OBUF, LED heartbeat all identical.
- `tn20k_hdmi720p60.gprj` — same device (`GW2AR-18C` / `GW2AR-LV18QN88C8/I7` / `gw2ar18c-000`),
  same RTL set, `top_720p60.v` + new sdc.
- `constraints/tn20k_720p60.sdc` — **identical clock numbers** to `tn20k_1080p30.sdc`
  (clk27 37.037, clk5 2.6936, clkpix 13.468). Separate file only so the two projects stay independent.

Modified (backwards compatible — defaults reproduce the old behaviour):
- `rtl/hdmi_timing.v` — the four H and four V constants became `parameter`s with the
  **original 1080p values as defaults**; the counting/sync logic is untouched.
- `rtl/pattern_gen.v` — bar width is now `H_ACTIVE/8` via a `parameter H_ACTIVE = 1920`
  (default 240 px bars = old behaviour; 720p gets 160 px bars so all 8 bars fit in 1280).
- `scripts/build.ps1` — two fixes, needed because there are now three `.gprj` variants sharing
  one `impl/`:
  1. copy-back now *merges* `impl/` instead of wiping it (pass `-CleanImpl` for the old behaviour),
     so building one variant no longer deletes the other variants' reports/bitstreams;
  2. the copy-back was `Copy-Item <dir> <existing dir> -Recurse`, which nests as `impl/impl/`;
     it now copies the directory *contents*.

**Untouched:** `rtl/pll_hdmi_371.v`, `rtl/tmds_encoder.v`, `rtl/top_1080p30.v`,
`rtl/top.v`, `rtl/pll_hdmi.v`, `constraints/tn20k.cst`, `constraints/tn20k_1080p30.sdc`,
`constraints/tn20k.sdc`, `scripts/build.tcl`.

**1080p30 still builds.** Rebuilt after the changes: exit 0, `.fs` produced again, and the
resource/timing signature is unchanged from the previously recorded numbers
(Logic 116, Register 77, CLS 65, Setup +7.823 ns, Fmax 177.159 MHz) — so the parameterisation
is a genuine no-op for that design.

## 6. How to rebuild

```powershell
cd hdmi-core
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 `
    -Project tn20k_hdmi720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.11.03_Education_x64
```

(The script must be launched under `powershell` with `-ExecutionPolicy Bypass` here: this host's
default policy is `Restricted`, so `& .\scripts\build.ps1` is refused outright.)
It mirrors `rtl/` + `constraints/` + all `*.gprj` into an ASCII `%TEMP%` dir, builds there, and
merges `impl/` back — the non-ASCII (`文档`) workspace path never reaches `gw_sh`.
Programmer CLI device string if you flash it: **`GW2AR-18C`**.

## 7. UNVERIFIED / not claimed

> 注：本节第 1、2、3 条描述的是**本报告成文之时**的状态，均已被后续的上板验证取代
> （见文首状态更新）。
> Note: items 1–3 below describe the state **at the time this report was written** and have all
> been superseded by the later on-hardware run (see the status update at the top).

- ~~**No hardware result.**~~ **已被取代 / SUPERSEDED：本变体已在真实电视机上验证。**
  本报告成文时没有接板子、没有烧录、没有观察电视画面，也没有测量 TMDS 眼图/偏斜；那段描述
  仅适用于当时。
  **This variant has since been verified on a real TV.** At the time of writing no board was
  connected, nothing was programmed, no TV picture was observed and no TMDS eye/skew was
  measured; that statement applies only to that moment.
- ~~**`OSER10`/`HCLK` at 371.25 MHz is not proven by STA**~~ (no fabric paths on that clock).
  **已被取代 / SUPERSEDED：** 该速率现已在真实板卡上跑出可见画面，与 nestang 的 720p 速率一致。
  That rate has since produced a visible picture on real hardware; it is the same rate nestang
  ships for 720p.
- ~~Colour-bar correctness at 1280 px active width is inferred from the RTL, not observed.~~
  **已被取代 / SUPERSEDED：1280 px 有效宽度的彩条已在电视上观察到。**
  The 1280 px colour bars have since been observed on a TV.
- The 15/16 LED pins and `sys_clk` on pin 4 are Tang Nano 20K facts from nestang's
  `nano20k.cst`; `gowin_check` warns about them because it assumes a *different* board
  (FG202 / GW1N-UV9LQ144, 50 MHz on IO98). Those warnings do not apply here — the same `.cst`
  is what the hardware-verified 1080p30 build used.
