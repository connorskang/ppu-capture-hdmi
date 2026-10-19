# PPU capture → HDMI **720p60** 变体（Tang Nano 20K / GW2AR-18）

**状态 / Status：RTL 完成，仿真通过（190,659 项检查，0 错误），在已授权的
Gowin V1.9.12 上编译通过（exit 0），像素域时序收敛（0 违例，Fmax 94.564 MHz，
约束 74.25 MHz）。没有任何东西上过板。**
**RTL complete, simulation-verified (190,659 checks, 0 errors), built with the
licensed Gowin V1.9.12 (exit 0), pixel-domain timing closed (0 violations,
Fmax 94.564 MHz against a 74.25 MHz constraint). Nothing was run on hardware.**

未在硬件上验证 —— 没有接板子、没有烧录、没有观察画面、没有测 TMDS 眼图。
完整的 UNVERIFIED 清单见 §8。
Not verified on hardware — no board attached, nothing programmed, no picture
observed, no TMDS eye measured. The full UNVERIFIED list is in §8.

工程目录：**`ppu-hdmi/`**（在原有集成工程里新增一个 720p60 变体，不另开子工程）。
Project directory: **`ppu-hdmi/`** (a 720p60 variant added inside the existing
integration project; no new subproject).

---

## 1. 做了什么 / What was built

```
 2C02 EXT0..3 ─┐
 VOUT slicers ─┼─> ppu_capture_intercept ──> 6-bit palette entry ─┐
 CPU $2006/07 ─┘   (verbatim from ppu-capture)                   │
                                                                  v
                                        ┌────────────────────────────────────┐
                                        │ ppu_framebuffer 256x240x6 (BSRAM)  │
                                        │  write: PPU dot clock              │
                                        │  read : 74.25 MHz pixel clock      │
                                        └──────────────┬─────────────────────┘
                                                       v
                        ppu_video_pipeline_720p  (this work)
                          stage A: 256 -> 768  (3x nearest, uniform)
                          stage B: 768 -> 960  (x1.25 sharp bilinear)  ] 4:3
                          or       256 -> 1024 (4x nearest)            ] 1:1
                          + 3x vertical + 3-phase scanline shading
                          + nes_palette  ->  RGB
                                                       v
                              hdmi_timing (CEA-861 VIC 4) + tmds_encoder x3
                                                       v
                                       OSER10 x4 + ELVDS_OBUF -> HDMI
```

| File | Status | Description |
|---|---|---|
| `rtl/ppu_video_pipeline_720p.v` | **new** | 720p60 读侧缩放：3 倍垂直 + 3 相扫描线 + 水平 4:3（3 倍整数 + 768→960 锐利双线性）/ 1:1（4 倍）。 |
| `rtl/ppu_hdmi_top_720p60.v` | **new** | 720p60 顶层。与 `ppu_hdmi_top.v` 的差别只有光栅常数和流水线实例。 |
| `ppu_hdmi_720p60.gprj` | **new** | 720p60 工程（器件、约束、引脚与 1080p30 完全相同）。 |
| `constraints/ppu_hdmi_720p60.sdc` | **new** | 四个时钟的**数值与 `ppu_hdmi.sdc` 完全一致**（720p60 的像素时钟也是 74.25 MHz）。 |
| `tb/tb_ppu_hdmi_720p.v` | **new** | 自检 testbench，两种模式并行。 |
| `sim/run_720p.ps1` | **new** | Icarus 运行脚本（镜像到 ASCII `%TEMP%`）。 |
| `sim/simulation_output_720p.txt` | new (build artefact, gitignored) | §5 引用的真实控制台输出。 |
| 其余 `rtl/*.v` | **未改动** | `ppu_video_pipeline.v`（1080p30 的缩放器）**逐字节未改**。 |

### 1.1 为什么是"新模块"而不是改原来那个 / Why a new module

`ppu_video_pipeline.v`（1080p30）**逐字节保持不变**，所以它那 219,694 项检查的
仿真结果和已记录的时序/资源指纹继续有效。720p60 换的是垂直系数（4→3）、扫描线
相位数（4→3），并且水平 4:3 从"整数 5 倍"变成"分数 1.25 倍"——结构不同。硬塞进
同一个模块只会让两边都变难验证，所以按"两个格式两个顶层、共用一个采集通路"的
方式组织，与 `hdmi-core/` 里 1080p30 / 720p60 两个 `.gprj` 的做法一致。

`ppu_video_pipeline.v` (1080p30) is **byte-identical to before**, so its
219,694-check simulation result and its recorded timing/resource signature stay
valid. 720p60 changes the vertical factor (4 → 3), the number of scanline
phases (4 → 3), and turns horizontal 4:3 from an integer 5x into a fractional
1.25x — a different structure. Forcing both into one module would make each
harder to verify, so this variant is organised as "two formats, two tops, one
shared capture path", matching how `hdmi-core/` keeps its 1080p30 and 720p60
`.gprj` files separate.

---

## 2. 几何 / Geometry

| | 4:3 模式 | 1:1 模式 |
|---|---|---|
| 水平 | 960 = 720 × 4/3（真 4:3） | 1024 = 256 × 4（方形像素） |
| 垂直 | 720 = 240 × 3 | 720 = 240 × 3 |
| H_START | **160** | **128** |
| 左右黑边 | 160 px | 128 px |
| V_START | **0** | **0** |
| 上下黑边 | 0（画面占满 720 行） | 0 |

720p 的 V_ACTIVE 正好等于 240×3，所以垂直方向**没有**黑边，V_START=0；
`de` 在 y ≥ 720 时恒为 0（仿真中专门检查了这一条）。

---

## 3. 垂直：4 倍 → 3 倍，相位 4 → 3

`sy = (cy - V_START) / 3`、`phase = (cy - V_START) mod 3`。实现上**没有除法器**：
用一个"行边界推进"的计数器（在 `cx == H_TOTAL-1` 时推进 `sy`/`vph`），
对任意 `V_SCALE` 都精确，且不占关键路径。

三个扫描线相位默认 **亮 / 半 / 暗 = 256 / 128 / 0（1/256 单位）**，都是 `parameter`
（`LVL0/LVL1/LVL2`）。三个值都是 2 的幂，所以常系数乘法在展开阶段退化成移位，
默认配置下这一级几乎不花逻辑。

**选择理由 / Why these three levels:** 240 行源在 720 行里每行重复 3 次，四相
（100/100/50/0）在 3 倍重复下会变成"亮/亮/半/暗"跨两个源行，相位与源行不再对齐；
三相 100/50/0 让每个源行的三行严格是"亮→半→暗"，垂直方向每个源行一个完整的
亮度周期，这正是 CRT 扫描线的样子。0% 那一行是纯黑，视觉上把行距拉开；50% 那一
行是过渡，避免 100%→0% 的硬跳变。

With 240 source lines repeated 3x, a four-phase pattern (100/100/50/0) would
straddle source lines; three phases 100/50/0 give every source line exactly one
bright → half → dark ramp, i.e. one full brightness cycle per source line, which
is what a CRT scanline looks like. The 0 % row is pure black (it opens up the
line spacing) and the 50 % row is the transition that avoids a hard 100→0 step.

---

## 4. 水平：4:3 = 3 倍整数 + 768→960 锐利双线性

960 / 256 = **3.75**，整数倍做不到 4:3；纯 Bresenham 会让"有的源列 3 列宽、有的
4 列宽"。按任务书用**两级**：

**第一级（stage A）**：256 → 768，整数 3 倍最近邻。源列 `s` 的 stage-A 索引是
`j = 3s, 3s+1, 3s+2` —— 每个源像素**正好**变成 3 个相同的采样点，绝对均匀。
仿真在 DUT 上验证：整行 767 次 stage-A 步进、相位严格 0,1,2 循环、源列递增 255 次，
且 768 = 256 × 3（另有一条纯算术自检，不依赖 DUT）。

**第二级（stage B）**：768 → 960（×1.25）。对输出列 `i`（画面内序号）：
```
j = floor(4i/5)            stage-A 位置
f = frac(4i/5)             f 只取 5 个值 {0, 1/5, 2/5, 3/5, 4/5}
f < T_LO      -> 取左（stage-A 的 j）
f > T_HI      -> 取右（stage-A 的 j+1）
否则          -> 按 f 线性混合
```
全部参数化（1/256 定点）：
`F0..F4 = 0,205,154,102,51`（即 frac(4r/5)，r = i mod 5）、
`T_LO = 51`（0.2）、`T_HI = 205`（0.8）、
`WGT0..WGT4 = -1` 表示"由 F/T 推导"，也可以直接给死权重（256 = 完全取右）。

### 4.1 混合为什么只在少数列可见 / Why the blend is mostly invisible

stage A 的相邻两个采样点 `A[j]`、`A[j+1]` 在 `j mod 3 ≠ 2` 时**是同一个源像素**，
混合结果与单像素完全相同。于是真正可见的混合只发生在"源列边界正好落在这一
输出列"的时候。

实测（仿真 + 算术复核）：960 列里**256 列发生真正的混合**，其余 **704 列
(73.33 %) 是纯粹的单源像素重复**。每 15 个输出列恰好 4 列混合（i ≡ 3,7,11,14
mod 15），也就是每个源列边界恰好 1 列渐变、其余全是硬边像素重复。

Measured (simulation plus an independent arithmetic recount): exactly **256 of
the 960 columns** are genuinely mixed and the other **704 (73.33 %)** are pure
single-source-pixel repeats — exactly one interpolated column per source-column
boundary, four per 15-column period (i ≡ 3, 7, 11, 14 mod 15).

> **关于任务书里的 "~90 % 保持锐利" / About the brief's "~90 % sharp":**
> 在 768→960 这个**量化**网格上 f 只有 5 个取值，任何阈值都只能让其中至多 2 个
> 走"纯取左/纯取右"分支，所以"纯"的比例与阈值无关，只由 `j mod 3` 决定 ——
> 上限就是 73.3 %。真正让它接近"锐利"的原因不是阈值，而是两级结构本身
> （stage-A 邻居常常就是同一个像素）。阈值参数留着是为了**调权重**：例如
> `T_LO=52` 会让 i≡4 (mod 5) 变成纯取左，`T_HI=204` 会让 i≡1 变成纯取右，
> 但可见混合列数不变（那些列本来 `A[j]==A[j+1]`）。这一点在报告里如实写出，
> 不去凑那个 90 %。
>
> On the quantised 768→960 lattice `f` takes only five values, so no threshold
> can push more than two of them into a "pure" branch: the pure fraction is
> fixed by `j mod 3`, and its ceiling is 73.3 %. What actually keeps the image
> sharp is the two-stage structure (stage-A neighbours are usually the same
> pixel), not the thresholds. The threshold parameters are still useful for
> tuning the *weights* (e.g. `T_LO=52` makes i ≡ 4 (mod 5) pure-left,
> `T_HI=204` makes i ≡ 1 pure-right), but they cannot change the number of
> visible blend columns. This is reported honestly rather than massaged to 90 %.

### 4.2 单读端口怎么同时拿到两个抽头 / Two taps from one read port

帧缓冲是半双端口的（一个读端口），而混合需要相邻两个抽头。**没有**复制帧缓冲
（25×2 > 46 块 BSRAM 放不下）。用的是地址序列单调这一性质：

```
raddr = sy*256 + M(i),   M(i) = s(i) + (a3(i)==2 ? 1 : 0)     (末列钳位到 255)
读延迟 1 拍 -> 第 i+1 拍时 fb_q = src[M(i)]
hsrc  : 记住"最近一次 a3 != 2 的列取到的像素" = src[s(i)]
idx_l = a3==2 ? hsrc : fb_q        ( = src[floor(j/3)] )
idx_r = fb_q                       ( = src[floor((j+1)/3)] )
```

`a3 == 2` 可以连续两列出现（例如 i=10、11），所以左抽头不能用"上一拍的数据"，
必须用这个带条件锁存的 `hsrc` —— 这一点在 §5 的列模式表里可以看到验证。

### 4.3 流水线 / Pipeline

从 `cx/cy` 到 `rgb` 正好 **4 拍**：
BSRAM 读寄存器 → 两次调色板查表打拍 → 常数权重混合 → 扫描线衰减 + 边框 + 输出
寄存器。`de`/`hsync`/`vsync` 与所有观测端口延迟同样的 4 拍，所以 TMDS 编码器看到
的 `(rgb, de, c0, c1)` 始终一致。

拆成 4 拍是**实测驱动的**：混合与衰减放在同一拍时，worst setup slack 只有
**1.970 ns**（Fmax 86.973 MHz）—— 够用但太薄。拆开后 worst slack 变成
**+2.893 ns**（Fmax 94.564 MHz），见 §6。

---

## 5. 仿真 / Simulation

工具：**Icarus Verilog 12.0**，plain Verilog-2001（`-g2005`），`C:\iverilog\bin\`。
运行：`powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_720p.ps1`

两个阶段：

* **Phase 1（PPU 点时钟 5.369 MHz）** — 通过 CPU 寄存器总线（`$2006`/`$2007`）
  写满 32 个调色板表项，然后驱动**三个完整的 NTSC 形状源帧**（341×262 点，
  256×240 有效，EXT0–3 + EXT4 上放已知图案，比较器形状的 `blank_i`/`vsync_i`），
  再通过层次化引用**逐条读回并校验全部 61,440 个帧缓冲表项**（两个实例各一遍）。
* **Phase 1b** — stage A 的整数重复性**纯算术**自检（不依赖 DUT）。
* **Phase 2（74.25 MHz 像素时钟）** — 一个完整的 **1650×750 720p60 帧**，
  两个 `ppu_video_pipeline_720p` 实例（4:3 与 1:1）喂同一份帧缓冲，同时读出来。

每个采样点检查：RGB（含混合 + 扫描线衰减）、实际取址 `raddr_o`、源列 `sx_o`、
stage-A 相位 `a3_o`、混合权重 `wgt_o` —— 后四项保证"颜色对但取错源像素"也会被抓到。

采样：**整行 1280 列全扫** 21 行（0–5、100、357–362、512、713–719），
外加**每一行的 10 列**（`cx % 128 == 0`）；两种模式各一遍。另有 27 个命名点。

### 5.1 真实控制台输出 / Actual console output

`sim/simulation_output_720p.txt`，逐字复制：
`sim/simulation_output_720p.txt`, reproduced verbatim:

```text
================================================================
 PPU capture -> framebuffer -> 720p60 scaler -> HDMI  test
 PPU dot clock 186.24 ns (5.369 MHz), video clock 13.468 ns (74.25 MHz)
 720p60 raster 1650x750 (60.000 Hz); active 1280x720
 picture 960x720 (4:3, 3x+1.25x sharp bilinear) / 1024x720 (1:1, 4x)
================================================================

=== PHASE 1: program palette shadow via $2006/$2007 ===
  wrote 32 palette entries ($3F00-$3F1F)
  driving 3 source frames: 341x262 dots, 256x240 active, EXT pattern
  checking framebuffer contents (256 x 240 entries, both instances) ...
  framebuffer: 61440 entries checked (1:1 and 4:3 instances)

=== PHASE 1b: stage-A integer-repeat model (256 columns -> 768 samples) ===
    PASS  stage A: 768 = 256 x 3 (4:3), 1024 = 256 x 4 (1:1), j monotone

=== PHASE 2: read out one 1650x750 (720p60) video frame ===
    col i=0 cx=128 | DUT sx=0 a3=0 w=0 addr=0 rgb=087c00 | exp sx=0 a3=0 addr=0 rgb=087c00  ok
    col i=1 cx=129 | DUT sx=0 a3=1 w=0 addr=0 rgb=087c00 | exp sx=0 a3=1 addr=0 rgb=087c00  ok
    col i=2 cx=130 | DUT sx=0 a3=2 w=0 addr=0 rgb=087c00 | exp sx=0 a3=2 addr=0 rgb=087c00  ok
    col i=3 cx=131 | DUT sx=0 a3=3 w=0 addr=0 rgb=087c00 | exp sx=0 a3=3 addr=0 rgb=087c00  ok
    col i=4 cx=132 | DUT sx=1 a3=0 w=0 addr=1 rgb=3032ec | exp sx=1 a3=0 addr=1 rgb=3032ec  ok
    col i=5 cx=133 | DUT sx=1 a3=1 w=0 addr=1 rgb=3032ec | exp sx=1 a3=1 addr=1 rgb=3032ec  ok
    col i=6 cx=134 | DUT sx=1 a3=2 w=0 addr=1 rgb=3032ec | exp sx=1 a3=2 addr=1 rgb=3032ec  ok
    col i=7 cx=135 | DUT sx=1 a3=3 w=0 addr=1 rgb=3032ec | exp sx=1 a3=3 addr=1 rgb=3032ec  ok
    col i=0 cx=160 | DUT sx=0 a3=0 w=0 addr=0 rgb=087c00 | exp sx=0 a3=0 w=0 addr=0 rgb=087c00  ok
    col i=1 cx=161 | DUT sx=0 a3=0 w=205 addr=0 rgb=087c00 | exp sx=0 a3=0 w=205 addr=0 rgb=087c00  ok
    col i=2 cx=162 | DUT sx=0 a3=1 w=154 addr=0 rgb=087c00 | exp sx=0 a3=1 w=154 addr=0 rgb=087c00  ok
    col i=3 cx=163 | DUT sx=0 a3=2 w=102 addr=1 rgb=175e5e | exp sx=0 a3=2 w=102 addr=1 rgb=175e5e  ok
    col i=4 cx=164 | DUT sx=1 a3=0 w=51 addr=1 rgb=3032ec | exp sx=1 a3=0 w=51 addr=1 rgb=3032ec  ok
    col i=5 cx=165 | DUT sx=1 a3=1 w=0 addr=1 rgb=3032ec | exp sx=1 a3=1 w=0 addr=1 rgb=3032ec  ok
    col i=6 cx=166 | DUT sx=1 a3=1 w=205 addr=1 rgb=3032ec | exp sx=1 a3=1 w=205 addr=1 rgb=3032ec  ok
    col i=7 cx=167 | DUT sx=1 a3=2 w=154 addr=2 rgb=175e5e | exp sx=1 a3=2 w=154 addr=2 rgb=175e5e  ok
    col i=8 cx=168 | DUT sx=2 a3=0 w=102 addr=2 rgb=087c00 | exp sx=2 a3=0 w=102 addr=2 rgb=087c00  ok
    col i=9 cx=169 | DUT sx=2 a3=1 w=51 addr=2 rgb=087c00 | exp sx=2 a3=1 w=51 addr=2 rgb=087c00  ok
    col i=10 cx=170 | DUT sx=2 a3=2 w=0 addr=3 rgb=087c00 | exp sx=2 a3=2 w=0 addr=3 rgb=087c00  ok
    col i=11 cx=171 | DUT sx=2 a3=2 w=205 addr=3 rgb=2840bc | exp sx=2 a3=2 w=205 addr=3 rgb=2840bc  ok
    col i=12 cx=172 | DUT sx=3 a3=0 w=154 addr=3 rgb=3032ec | exp sx=3 a3=0 w=154 addr=3 rgb=3032ec  ok
    col i=13 cx=173 | DUT sx=3 a3=1 w=102 addr=3 rgb=3032ec | exp sx=3 a3=1 w=102 addr=3 rgb=3032ec  ok
    col i=14 cx=174 | DUT sx=3 a3=2 w=51 addr=4 rgb=2840bc | exp sx=3 a3=2 w=51 addr=4 rgb=2840bc  ok
    col i=15 cx=175 | DUT sx=4 a3=0 w=0 addr=4 rgb=087c00 | exp sx=4 a3=0 w=0 addr=4 rgb=087c00  ok
    col i=16 cx=176 | DUT sx=4 a3=0 w=205 addr=4 rgb=087c00 | exp sx=4 a3=0 w=205 addr=4 rgb=087c00  ok
    col i=17 cx=177 | DUT sx=4 a3=1 w=154 addr=4 rgb=087c00 | exp sx=4 a3=1 w=154 addr=4 rgb=087c00  ok
    col i=18 cx=178 | DUT sx=4 a3=2 w=102 addr=5 rgb=175e5e | exp sx=4 a3=2 w=102 addr=5 rgb=175e5e  ok
    col i=19 cx=179 | DUT sx=5 a3=0 w=51 addr=5 rgb=3032ec | exp sx=5 a3=0 w=51 addr=5 rgb=3032ec  ok

---- picture rectangle (whole-row census on row 360) ----
    PASS  [4:3] picture columns 160..1119, width 960 (bars 160 px each side)
    PASS  [1:1] picture columns 128..1151, width 1024 (bars 128 px each side)
    PASS  vertical: 720 picture rows in both modes, 0 rows with de below y=720

---- stage A observed on row 0 (DUT) ----
    PASS  [4:3] 767 stage-A steps, 255 source-column increments, phase 0,1,2 strict
    PASS  [1:1] 1023 stage-A steps, 255 source-column increments, phase 0,1,2,3 strict
    PASS  4:3 = 768 stage-A samples over 960 output columns (4 of every 5 columns)

---- 4:3 mode: 960x720, h_start 160, v_start 0, 3x + 1.25x sharp bilinear ----
    PASS  bar before TL   px(159,0) src(0,0) a3=0 w=0 ph0  rgb 303030
    PASS  picture TL      px(160,0) src(0,0) a3=0 w=0 ph0  rgb 087c00
    PASS  scanline ph1    px(160,1) src(0,0) a3=0 w=0 ph1  rgb 043e00
    PASS  scanline ph2 0% px(160,2) src(0,0) a3=0 w=0 ph2  rgb 000000
    PASS  next line ph0   px(160,3) src(0,1) a3=0 w=0 ph0  rgb 087c00
    PASS  left edge y360  px(160,360) src(0,120) a3=0 w=0 ph0  rgb 087c00
    PASS  picture TR      px(1119,0) src(255,0) a3=2 w=51 ph0  rgb 006678
    PASS  picture BR      px(1119,717) src(255,239) a3=2 w=51 ph0  rgb 081090
    PASS  bar after TR    px(1120,0) src(0,0) a3=0 w=0 ph0  rgb 303030
    PASS  scanline ph0    px(400,0) src(64,0) a3=0 w=0 ph0  rgb 087c00
    PASS  scanline ph1    px(400,1) src(64,0) a3=0 w=0 ph1  rgb 043e00
    PASS  scanline ph2 0% px(400,2) src(64,0) a3=0 w=0 ph2  rgb 000000
    PASS  blend column    px(639,360) src(127,120) a3=2 w=51 ph0  rgb 2632c8

---- 1:1 mode: 1024x720, h_start 128, v_start 0, 4x ----
    PASS  bar before TL   px(127,0) src(0,0) a3=0 w=0 ph0  rgb 303030
    PASS  picture TL      px(128,0) src(0,0) a3=0 w=0 ph0  rgb 087c00
    PASS  scanline ph1    px(128,1) src(0,0) a3=0 w=0 ph1  rgb 043e00
    PASS  scanline ph2 0% px(128,2) src(0,0) a3=0 w=0 ph2  rgb 000000
    PASS  next line ph0   px(128,3) src(0,1) a3=0 w=0 ph0  rgb 087c00
    PASS  bottom-left     px(128,719) src(0,239) a3=0 w=0 ph2  rgb 000000
    PASS  4x repeat col 3 px(131,0) src(0,0) a3=3 w=0 ph0  rgb 087c00
    PASS  4x repeat col 4 px(132,0) src(1,0) a3=0 w=0 ph0  rgb 3032ec
    PASS  picture TR      px(1151,0) src(255,0) a3=3 w=0 ph0  rgb 006678
    PASS  bar after TR    px(1152,0) src(0,0) a3=0 w=0 ph0  rgb 303030
    PASS  scanline ph0    px(400,0) src(68,0) a3=0 w=0 ph0  rgb 087c00
    PASS  scanline ph1    px(400,1) src(68,0) a3=0 w=0 ph1  rgb 043e00
    PASS  scanline ph2 0% px(400,2) src(68,0) a3=0 w=0 ph2  rgb 000000
    PASS  centre pixel    px(639,360) src(127,120) a3=3 w=0 ph0  rgb 3032ec

================================================================
 framebuffer entry checks : 61440
 swept pixel checks       : 67740
 stage-A / geometry checks: 4
 named point checks       : 27
 total checks             : 190659
 errors                   : 0
 RESULT: PASS
================================================================
```

### 5.2 逐项含义 / What each result means

| 观察 / Observation | 含义 / Meaning |
|---|---|
| 4:3 `picture columns 160..1119, width 960` | 整行普查（逐列数"非边框列"）：画面正好 960 列、左右各 160 px 黑边。不是抽样推断。 |
| 1:1 `picture columns 128..1151, width 1024` | 同上，1:1 模式 1024 列、左右各 128 px。 |
| `vertical: 720 picture rows ... 0 rows with de below y=720` | 垂直方向画面占满 0..719；`de` 在 720 行以下**一次都没有**有效 → V_START=0 无上下黑边。 |
| `[4:3] 767 stage-A steps, 255 source-column increments, phase 0,1,2 strict` | stage A 从 DUT 观测：767 次步进 ⇒ 768 个采样点；相位严格 0→1→2→0；源列递增正好 255 次 ⇒ 每列 3 个采样点。 |
| `[1:1] 1023 steps / 255 increments / phase 0,1,2,3` | 1:1 模式 1024 个采样点、每列 4 个。 |
| 4:3 `picture TL (160,0) src(0,0)` | 画面左上角 = 源 (0,0)，落在 H_START=160 / V_START=0。 |
| 4:3 `TR (1119,0) src(255,0)`、`BR (1119,717) src(255,239)` | 最后一列 i=959：`j=767`、`a3=2`、右抽头越界被钳位到源列 255，混合退化成"同一像素" —— 边界行为正确。 |
| 4:3 `scanline ph1/ph2` 在 (400,0/1/2) | 同一个源像素 (64,0) 在 100 % / **50 %**（0x087c00 → 0x043e00，逐通道精确减半）/ **0 %**（0x000000）。三相落在正确的行上。 |
| 4:3 `next line ph0 (160,3) src(0,1)` | 相位 3 行一轮回，源行 +1。3 倍垂直被证明到"行"这一级。 |
| 1:1 `4x repeat col 3 (131) src(0,0)` vs `col 4 (132) src(1,0)` | 精确 4 倍：128–131 四列都是源列 0，132 起是源列 1。 |
| `blend column (639,360) src(127,120) a3=2 w=51` | 混合列：i=479，`j=383`、`a3=2`、`w=51`（0.2），结果 `2632c8`。 |

### 5.3 混合算术的手工复核 / Hand verification of the blend arithmetic

从上面的列模式表取两列，用**另一个来源**（源图案 → 调色板表 → 手工乘加）复算：

**列 i=3（cx=163，w=102）：** 左 = 源列 0 = `087c00`，右 = 源列 1 = `3032ec`。
```
R = (0x08*(256-102) + 0x30*102) >> 8 = (8*154 + 48*102) >> 8 = 6128 >> 8 = 23 = 0x17
G = (0x7c*154        + 0x32*102) >> 8 = (124*154 + 50*102)>> 8 = 24196>> 8 = 94 = 0x5e
B = (0x00*154        + 0xec*102) >> 8 = (0 + 236*102)      >> 8 = 24072>> 8 = 94 = 0x5e
-> 0x175e5e   == DUT rgb 175e5e   ✓
```
**列 i=11（cx=171，w=205）：** 左 = 源列 2 = `087c00`，右 = 源列 3 = `3032ec`。
```
R = (8*51 + 48*205) >> 8 = 10248 >> 8 = 40  = 0x28
G = (124*51 + 50*205)>> 8 = 16574 >> 8 = 64  = 0x40
B = (0    + 236*205) >> 8 = 48380 >> 8 = 188 = 0xbc
-> 0x2840bc   == DUT rgb 2840bc   ✓
```
两列都是**混合**（左 ≠ 右），并且都精确等于"按权重 1/256 定点的线性插值再
向下取整"。i=10 是 `a3=2` 但 `w=0` —— 结果 `087c00` 就是源列 2 本身，说明
"边界上仍然可以有纯像素列"这条性质真的存在。

Both columns are genuine blends (left ≠ right) and match the 1/256 fixed-point
linear interpolation with truncation exactly. i=10 has `a3=2` but `w=0` and comes
out as the untouched source pixel, confirming that boundary columns can still be
pure.

### 5.4 检查计数 / check accounting

| 类别 | 数量 |
|---|---|
| 帧缓冲表项（61,440 × 2 实例） | 122,880（记为 61,440 次「表项检查」，每次检查两个实例） |
| 采样像素（两种模式合计） | 67,740 |
| stage-A / 几何整块检查 | 4 |
| 命名点 | 27 |
| **合计** | **190,659**，errors **0** |

仿真时长 66.7 ms（50 ms 采集 + 16.7 ms 读出），约 124 万视频像素时钟，
wall-clock ≈ 2 min。VCD 默认关闭（`run_720p.ps1 -Vcd` 才写）。

**这个仿真没有覆盖**：OSER10 串行器、rPLL/CLKDIV（高云原语，在视频流水线之外）、
模拟 VOUT 比较器、三态总线收发器、真实 2C02 行为。TMDS 编码器由
`tb_tmds_pipe_equiv.v` 单独证明（1080p30 那份，未改动）。

### 5.5 1080p30 没有被破坏 / 1080p30 is unbroken

`ppu_video_pipeline.v` / `tb_ppu_hdmi.v` / `ppu_hdmi.gprj` / `ppu_hdmi.sdc` 全部
未改动（`git status` 里它们不出现）。重跑原仿真：**219,694 项检查、0 错误、
RESULT: PASS** —— 与 `REPORT.md` §4 记录的数字逐字一致。重编译 `ppu_hdmi.gprj`
（同一台 V1.9.12、同一组选项）也复现了 `REPORT.md` §5 的全部指纹：

| | `REPORT.md` §5 记录值 | 本次重编译 |
|---|---|---|
| 退出码 / `.fs` | 0 / 有 | **0 / 有**（7,264,150 字节，MD5 `8DB3DBFC…`） |
| Logic / Register / CLS | 656 / 217 / 390 | **656 / 217 / 390** |
| BSRAM / I-O / IOLOGIC | 25 / 49 / 8 | **25 / 49 / 8** |
| `clkpix` Fmax | 120.564 MHz | **120.564 MHz** |
| 最差 setup slack / 路径 | +5.174 ns，`u_enc0/d_r_4_s0` → `u_enc0/acc_5_s0`，8.259 ns | **完全相同** |
| setup/hold 违例 | 0 / 0 | **0 / 0** |

也就是说：本变体是**纯增量**的 —— 除了新增文件，1080p30 那条路径的综合/布局/
布线结果是逐项可复现的，不是"看起来没坏"。

In other words this variant is purely additive: apart from the new files, the
1080p30 build reproduces every recorded number item for item.

---

## 6. 构建 / Build（授权的 Gowin V1.9.12）

```powershell
cd ppu-hdmi
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 `
    -Project ppu_hdmi_720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64 `
    -Task all -PlaceOption 1 -RouteOption 2 -TimingDriven 1 `
    -GlobalFreq 74.25 -CorrectHold 0 -Replicate 1
```

**退出码 0；码流产生：`impl/pnr/ppu_hdmi_720p60.fs`，7,264,150 字节。**
器件 `GW2AR-18C` / `GW2AR-LV18QN88C8/I7` / 版本 C（`gw2ar18c-000`），
与 1080p30 工程和已上板验证的 hdmi-core 工程相同。

### 6.1 时序：像素域收敛 / Timing: closed

来自 `impl/pnr/ppu_hdmi_720p60_tr_content.html`：

| 时钟 | 约束 | Setup 最差 slack | Hold 最差 slack | 实际 Fmax | 违例 |
|---|---|---|---:|---:|---|
| `clkpix`（像素） | 74.250 MHz / 13.468 ns | **+2.893 ns** | 0 违例 | **94.564 MHz** | **0**（TNS 0.000） |
| `clk27`（晶振） | 27.000 MHz / 37.037 ns | 0 违例（TNS 0.000） | 0 违例 | 233.292 MHz | 0 |
| `ppupix`（2C02 点时钟） | 5.369 MHz / 186.24 ns | 0 违例（TNS 0.000） | 0 违例 | 93.081 MHz | 0 |
| `clk5`（串行器） | 371.25 MHz / 2.6936 ns | — | — | *"No timing paths to get frequency of clk5"* | n/a — **预期，不是放行** |

全设计最差的 hold slack 是 **+0.218 ns**（`ppupix` 域，`u_video/wp_*` → 帧缓冲地址），
正数即合格；setup 侧最差是上表 clkpix 的 +2.893 ns。

`Numbers of Setup Violated Endpoints 0` / `Numbers of Hold Violated Endpoints 0`；
`Total Negative Slack` 对 clk27 / clk5 / clkpix / ppupix 及三个 rPLL 生成时钟
全部为 **0.000**。最小脉宽检查最差 slack 4.971 ns（要求 1.0 ns）。

像素域余量：**94.564 / 74.250 = 1.27 倍**。

**关键路径（诚实版）/ Critical path (honest version)：**
`u_video/pal_l_d[*]` → `bl_rgb_*`（4 级逻辑），data delay 10.540 ns、slack +2.893 ns。
其中有一段是 **DSP 内部 3.760 ns**：混合的“常系数乘加”被工具综合进 DSP48
（资源表里 `DSP 12/24`），DSP 的进出布线比 LUT 加法树慢。第一版把混合和衰减放在
同一拍时 worst slack 只有 **1.970 ns**（Fmax 86.973 MHz）；拆成两拍后变成
2.893 ns。**没有**去关那个 DSP 推断 —— 2.893 ns 的余量对 74.25 MHz 已经足够，
而强行用 LUT 加法树反而会把组合深度拉长（那正是 1080p30 报告里试过并放弃的路子）。

The critical path runs through a **DSP slice** (3.760 ns inside the DSP): the
constant-coefficient multiply-add of the blend got mapped to DSP48 (resources:
`DSP 12/24`), whose I/O routing is slower than a LUT adder tree. With blend and
attenuation in one stage the worst slack was only 1.970 ns (Fmax 86.973 MHz);
splitting them gives 2.893 ns. The DSP inference was deliberately left alone —
2.893 ns is ample for 74.25 MHz, and forcing a LUT adder tree would deepen the
combinational path (that is the route the 1080p30 report tried and rejected).

### 6.2 资源 / Resources

| 资源 | 用量 | 可用 | 占比 |
|---|---:|---:|---:|
| Logic | 771 | 20,736 | 4 % |
| Register | 298 | 15,750 | 2 % |
| CLS | 462 | 10,368 | 5 % |
| **BSRAM** | **26** | **46** | **57 %** |
| DSP | 12 | 24 | 50 % |
| I/O Port | 49 | 66 | 75 % |
| IOLOGIC | 8 | 121 | 7 % |
| rPLL | 1 | 2 | 50 % |
| CLKDIV | 1 | 8 | 13 % |

与 1080p30 构建（Logic 656 / Register 217 / CLS 390 / BSRAM 25）相比：
Logic +115、Register +81、CLS +72（两倍调色板查表 + 混合 + 多一级流水线）、
BSRAM +1（第二份 64×24 调色板表被推断进 BSRAM）、新增 DSP 12。
BSRAM 仍是 26/46 —— 帧缓冲没变，单帧缓冲的前提没被破坏。

### 6.3 告警：全部逐条看过 / Warnings: all read

| 告警 | 次数 | 评估 |
|---|---:|---|
| `WARN (CV0016) Input hsync_i is unused`（`ppu_hdmi_top_720p60.v:93`） | 1 | 属实：线性写指针只需要 `vsync`。与 1080p30 构建同一条。 |
| `WARN (NL0002) … swept in optimizing`：`nes_palette`(×2)、`ppu_pixel_out` | 3 | 展平后的提示，模块名消失在父模块逻辑里。调色板输出确实存在（仿真证明颜色对），父工程同样有。 |
| `WARN (TA1117) Can't calculate clocks' relationship between ppupix and clk27` | 2 | 预期 —— 两者异步。唯一真实的跨域是双时钟 BSRAM 的写/读端口，不需要时序关系。 |
| `WARN (PR1014) Generic routing … 'sys_clk_d'` | 1 | 父工程既有（27 MHz 晶振进 rPLL）。 |
| `WARN (EX3791)` 位宽截断 | **0** | 本轮已清掉：`mix8`/`scale8` 的中间积用显式 17 位，`p[15:8]` 取结果，不再有任何截断。 |
| `alog error: failed to open log file …sh.log` | 1 | `gw_sh` 的 stderr 噪声，每次运行都有，无害。 |
| **`EX0205 / EX0206 / EX0210 / EX0214 / PA1019 / TA1123`** | **0** | **没有 PLL 参数被静默替换，也没有时钟频率不匹配。** |

### 6.4 PLL 干净 —— 这是"能生成码流"之外的独立证据 / The PLL report is clean

`PLL-742-TEST.md` 记录的坑是：高云会**静默替换**非法的 rPLL 参数，照样吐出
码流。所以这里不能只看"exit 0 + 有 .fs"，要看 PLL 的实际结果：

* STA 的 **Clock Summary** 里列出的生成时钟是
  `u_pll/rpll_inst/CLKOUTP → 371.250 MHz`、`CLKOUTD → 185.625`、
  `CLKOUTD3 → 123.750` —— 也就是 rPLL **真的**输出 371.25 MHz，不是替换值；
* `clkpix`（CLKDIV /5）在 Clock Summary 里是 **74.250 MHz / 13.468 ns**，
  与 sdc 一致；
* `pll_hdmi_371.v` 的参数未被修改：`IDIV_SEL=3`（/4）、`FBDIV_SEL=54`（×55）、
  `ODIV_SEL=2` → `27/4*55 = 371.25 MHz`，再 CLKDIV /5 = 74.25 MHz。
  这正是 hdmi-core 里**已在真实电视机上跑出画面**的那套配置
  （见 `hdmi-core/720P60_REPORT.md` §1）；
* 零个 `EX0210`（"Invalid CLKOUT frequency … suitable range is 3.90625 MHz to
  625 MHz"）—— 742.5 MHz 那条会触发它，371.25 MHz 不会。

### 6.5 引脚 / Pins

板级引脚与已上板验证的 hdmi-core / 1080p30 工程**逐脚相同**（`.pin.html` 核对）：
`sys_clk` **4**；TMDS 时钟 **33/34**、数据 **35/36、37/38、39/40**（全部
`LVCMOS33D`，DRIVE=8，Bank 3.3 V）；LED **15/16**。
**PPU 侧端口仍然只有电气属性、没有 `IO_LOC`**（还没有转接板），本构建里被自动
布局到 10（`ppu_pix_clk`）、17（`rst_n`）、57/77/86/48/41（CPU 侧）、
30/27/31/32/29/28/25（EXT/时序）等 —— **这份自动布局不能直接上手焊板**，
上板前必须补引脚（与 1080p30 的结论相同）。

---

## 7. 相对 1080p30 到底改了什么 / What actually changed

| 项 | 1080p30（`ppu_hdmi*`） | 720p60（本变体） |
|---|---|---|
| 光栅 | 2200×1125（VIC 16） | **1650×750（VIC 4）** |
| 像素时钟 | 74.25 MHz | 74.25 MHz（**不变**） |
| rPLL / CLKDIV | 371.25 MHz / ÷5 | **完全不变** |
| TMDS 串行率 | 371.25 MHz | **不变** |
| 垂直倍数 | 4（960 行） | **3（720 行）** |
| 扫描线相位 | 4 相 100/100/50/0 | **3 相 亮/半/暗 256/128/0** |
| 垂直黑边 | 上下各 60 px | **0**（画面占满 720 行） |
| 水平 4:3 | 1280 = 5 倍整数 | **960 = 3 倍整数 + 768→960 ×1.25 锐利双线性** |
| 水平 1:1 | 1024 = 4 倍整数 | 1024 = 4 倍整数（**不变**） |
| 4:3 左右黑边 | 320 px | **160 px** |
| 1:1 左右黑边 | 448 px | **128 px** |
| 帧缓冲 / 调色板 / 边框 / 采集通路 | — | **完全未改** |
| 流水线延迟 | 2 拍 | 4 拍（多两级为了时序，见 §4.3） |

---

## 8. 没验证的部分（明确清单）/ UNVERIFIED (explicit list)

1. **没有硬件。** 没接板子、没烧录、没看过电视画面、没测 TMDS 眼图/偏斜。
   `impl/pnr/ppu_hdmi_720p60.fs`（构建后被删除，见 §9）是一个时序干净的构建
   产物，不是"能出画面"的证明。
2. **`clk5` @ 371.25 MHz 不被 STA 证明** —— 它只连到 OSER10 的 `FCLK` 引脚，
   没有 fabric 端点可分析。真正的限制是 PLL 规格（CLKOUT ≤ 625 MHz，
   371.25 比它低 41 %）。这个速率在 hdmi-core 里上过板，但**本工程的码流没有**。
3. **PPU 侧引脚不存在**（§6.5）。`ppu_pix_clk` 落在普通 I/O 10 上，不是时钟专用
   引脚 —— 上板前必须换成时钟 capable 引脚，否则 5.369 MHz 的采集时钟会走普通
   布线。
4. **`ppu_pix_clk` 假设是 2C02 点时钟（5.369 MHz）**，真实来源（PPU CLK ÷4 或
   比较器 slicer）、相位、是否时钟 capable 都未定义。采集域的 `clk` 在顶层是
   27 MHz 晶振，而 ppu-capture 的 testbench 用的是 4× 点时钟 —— injector 的
   时序假设在板级没有验证。
5. **没有跨时钟域分析**，除了"双时钟 BSRAM"。`ppupix → clkpix` 之间没有同步器
   （没有握手），读侧可能看到撕裂的一帧（单缓冲的已知后果）。
6. **强调色 / 灰度被采集但没有施加**到 RGB 输出。
7. **锐利双线性的视觉质量没有主观评价**。仿真只能证明它按定义的规则输出；
   73.3 % 纯列 / 26.7 % 混合列在真实电视上看起来如何、与纯 4 倍 nearest
   （1024 宽、方形像素）相比观感差异，只能上板判断。混合权重是否要调
   （`WGT0..WGT4`/`T_LO`/`T_HI`）也是同一个问题。
8. **3 相扫描线（100/50/0）的观感未验证**。0 % 那一行是纯黑，在 720p 上会不会
   显得"行太黑"、是否需要改成 0 %→10 % 之类的，只能上板看。参数已经留出。
9. **TMDS 编码器的流水线等价性证明来自 1080p30 的那份 testbench**
   （200,000 周期、0 不匹配），本次没有重跑；`rtl/tmds_encoder.v` 未改动。
10. **PLL/OSER10/ELVDS_OBUF 原语沿用父工程**，其出处是父工程的 1080p30 与
    720p60 上板运行，不是本构建。
11. **帧缓冲写指针假设每帧 256×240 有效像素**（`REPORT.md` §2.1），本变体未改。
12. 隔行/奇数 NES 帧、sprite-0 命中时序、模拟 VOUT slicer 都不在本工作范围内
    （见 `ppu-capture/REPORT.md` §6，含"驱动 EXT0–3 前必须先解除接地"的安全警告）。

---

## 9. 仓库状态 / Repository state

* 没有留下 `.fs`、`impl/`、`*.vcd`、`*.log`、`*.html`、`*.timing_paths` ——
  构建产物在取数后被删除，`impl/` 是 `.gitignore` 里的第一行。
* `sim/simulation_output_720p.txt` 与 `sim/simulation_output.txt` 是
  `simulation_output*.txt`（gitignored）—— 留在磁盘上作为可直接对照的证据。
* 两个 `.gprj` 并存，各自独立；`ppu_hdmi.gprj`（1080p30）的文件表一个字节都没改。
* `.cst` / `.sdc` 为 **UTF-8 无 BOM**；`.ps1` 为 **UTF-8 带 BOM**（见
  `REPORT.md` §6 的编码规则）。

---

## 10. 下一步 / Next step

1. **先单独验证视频通路**：把帧缓冲写端口接一个内置计数器（不需要 NES），
   4:3 构建上电视，确认 960×720 画面、左右各 160 px 黑边、无上下黑边、
   三档扫描线。这一步覆盖 §1 里除采集通路以外的全部内容。
2. 同一份 RTL 用 `H_MODE_4_3=0` 重编译，对比 1024 宽（方形像素）的观感，
   决定哪种作为默认（当前默认 **4:3**）。
3. 再补 PPU 侧引脚（`ppu_pix_clk` 优先时钟 capable 脚），接 2C02 转接板，
   最后才打开 `capture_en`；用 GAO 抓 `pix_index`/`pix_valid`/`vsync_i`。
