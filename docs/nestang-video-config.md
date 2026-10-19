# NESTang video output configuration — verified from source

Repo: **https://github.com/nand2mario/nestang** (author: nand2mario). Confirmed as the right project:
README title "NESTang - NES for Sipeed Tang FPGA Boards", `nestang_nano20k.gprj`, `src/nestang_top.sv`.

**Important: the repo contains two different video pipelines.**

| | Last standalone release **v0.12** (2024-11-16) | **master / TangCore** (since commit e9f5d56, 2025-02-04) |
|---|---|---|
| Output raster | 1280x720@60 | 1280x720@60 (same) |
| Pixel clock | 74.25 MHz | 74.25 MHz (same) |
| Active picture area | **877 x 720** (8:7 mode, default) or **768 x 720** (1:1 mode) | **960 x 720** |
| H scale | 24/7 = 3.4286x (8:7) or 3x (1:1) | 960/256 = **3.75x** |
| V scale | **3x** fixed (all 240 lines) | 720/224 = **3.2143x** (240 lines cropped to 224) |
| Missing lines | none | 8 top + 8 bottom dropped |
| Pillarbox | 199 / 204 px (8:7), 254 / 258 px (1:1) | **160 / 160 px** |
| Border colour | black (24'h000000) | **24'h303030** (dark grey) |

The v0.12 file is `src/nes2hdmi.sv` at tag v0.12; the current one is `src/nes2hdmi.sv` on master.
TangCore (github.com/nand2mario/tangcore) pins nestang at commit `c2450818` (2025-05-01), i.e. it
ships the **960x720** version. The downloadable `nestang-0.12.zip` bitstream is the **877x720** version.

## 1. Board / FPGA
- Tang Nano 20K: `set_device GW2AR-LV18QN88C8/I7 -device_version C` (`build.tcl`, nano20k branch)
  -> GW2AR-18. Also supported: Primer 25K (GW5A-25), Mega 60K (GW5AT-60), Mega 138K (GW5AST-138).
- Note `nestang_nano20k.gprj` is stale (references `src/nano20k/*` which no longer exists); `build.tcl` is authoritative.

## 2. Resolution / refresh
`localparam FRAMEWIDTH = 1280; FRAMEHEIGHT = 720; VIDEOID = 4; VIDEO_REFRESH = 60.0;`
VIDEO_ID_CODE 4 in `src/hdmi2/hdmi.sv` = frame 1650x750, screen 1280x720, hsync_start 110 / size 40,
vsync_start 5 / size 5. 74.25e6 / (1650*750) = **60.000 Hz exactly** (no 1000/1001 factor).

## 3. Pixel clock
- 27 MHz crystal -> rPLL -> **371.25 MHz** (comment: `371.25 = 27 * 55 / 4`) -> `CLKDIV DIV_MODE(5)` -> **74.25 MHz**
- `src/pllr/gowin_pll_hdmi.v`: FCLKIN="27", IDIV_SEL=3, FBDIV_SEL=54, ODIV_SEL=2, DEVICE="GW2AR-18"
- `src/boards/nano20k.sdc`: `create_clock -name hclk5 -period 2.6936` (= 371.25 MHz)
- TMDS serialiser runs at 5x pixel clock (371.25 MHz), `localparam SCALE = 5` is the TMDS 5x ratio, NOT a picture scale.
- NES main clock is separate: 27 MHz -> rPLL -> 64.8 MHz fclk -> /3 = 21.6 MHz (`clk`).

## 4. Scaling (master, 960x720)
Fractional Bresenham-style counters, nearest-neighbour pixel repeat, no blending:
```
localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3  -> 160
localparam XSTOP  = (1280 + 960) / 2;   //                 -> 1120
xcnt_next = xcnt + 256;   if (xcnt_next >= 960) { xcnt <= xcnt_next-960; xx <= xx+1; }
ycnt_next = ycnt + 224;   if (ycnt_next >= 720) { ycnt <= ycnt_next-720; yy <= yy+1; }
assign mem_portB_addr = yy * WIDTH + xx + 8*256;   // skip 8 top lines
```
H = 3.75 px/px (pattern ...4,4,4,3...), V = 3.2143 lines/line. Header comment:
"NES generates 256x240. We assume the center 256x224 is visible and scale that to 4:3 aspect ratio."

## 5. Scaling (v0.12, released)
```
assign y = ONE_THIRD[cy];          // LUT: y = cy/3, 240*3 = 720 exactly
assign mem_portB_addr = {y, x};
```
H: 8:7 mode = 24 output px per 7 NES px (mixed edge pixels 110/146, 219/37, 73/183, 183/73, 37/219, 146/110),
total width 36*24+13 = 877, active cx 199..1075. 1:1 mode = exactly 3x repeat, 768 px.
V: exactly 3x, all 240 lines shown.

## 6. Files
- `src/nes2hdmi.sv` — video timing window, scaling, palette, BRAM frame buffer
- `src/hdmi2/hdmi.sv` — CEA-861 timing generator (VIDEO_ID_CODE 4), TMDS
- `src/hdmi2/serializer.sv`, `tmds_channel.sv` — 5x serialiser
- `src/pllr/gowin_pll_hdmi.v` — 27 MHz -> 371.25 MHz
- `src/nestang_top.sv` — `CLKDIV #(.DIV_MODE(5))` -> hclk 74.25 MHz
- `src/boards/nano20k.sdc`, `src/boards/nano20k.v` (`define PLL_R`), `build.tcl`

## 7. Framebuffer
Single full-frame buffer, no line buffers, no double buffering:
`localparam MEM_DEPTH=256*240; logic [5:0] mem [0:256*240-1];` = 61,440 x 6 bit = 368,640 bit (~45 KB, ~44% of GW2AR-18's 828 kbit BSRAM).
Port A written by NES pixel clock, port B read by 74.25 MHz pixel clock -> possible tearing.
