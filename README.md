# ppu-capture-hdmi

**PPU 总线抓取 + HDMI 输出的 8 位主机改机工程**（面向使用 2C02 类 PPU 的主机）
**A PPU bus capture + HDMI output mod for 8-bit consoles that use a 2C02-style PPU**

---

## 目录 / Table of contents

- [1. 这是什么 / What this is](#1-这是什么--what-this-is)
- [2. 当前状态 / Current status](#2-当前状态--current-status)
- [3. 仓库结构 / Repository layout](#3-仓库结构--repository-layout)
- [4. 硬件要求 / Hardware requirements](#4-硬件要求--hardware-requirements)
- [5. 构建 / How to build](#5-构建--how-to-build)
- [6. 仿真 / How to run the simulations](#6-仿真--how-to-run-the-simulations)
- [7. 编码注意事项 / Encoding notes](#7-编码注意事项--encoding-notes)
- [8. 许可证 / Licence](#8-许可证--licence)

---

## 1. 这是什么 / What this is

**中文**

这是一个针对使用 **2C02 类 PPU** 的 8 位主机的**视频抓取 + HDMI 输出**改机工程。
它由三个可独立验证的部分组成：

1. **`hdmi-core`** —— 一个纯 Verilog 的 HDMI（TMDS）输出核，跑在 Sipeed **Tang Nano 20K**
   （高云 **GW2AR-18**）上。它自己产生 CEA-861 光栅、做 TMDS 8b/10b 编码，并用高云的
   `OSER10` 硬核串行化。当前输出的是彩条测试图案，**不接主机也能点亮电视**。
2. **`ppu-capture`** —— PPU 总线转接板（interposer）逻辑：在 CPU 侧的 PPU 寄存器总线上
   强制 `$2000` bit 6（EXT 输出方向），抓取 `EXT0..EXT3` 的 4 位像素颜色，从 VOUT 比较器
   恢复第 5 位（背景/精灵），并用一份从 `$2006/$2007` 写操作重建的**调色板 RAM 影子**
   还原出 6 位颜色索引。
3. **`ppu-hdmi`** —— 前两者的集成：抓取 → 256×240×6 帧缓冲（BSRAM）→ 水平缩放
   （1:1 的 4 倍 或 4:3 的 5 倍）→ 垂直 4 倍 + 扫描线明暗 → 调色板 → RGB → TMDS → HDMI。

**English**

This is a **video capture + HDMI output** mod for 8-bit consoles that use a **2C02-style
PPU**. It consists of three independently verifiable parts:

1. **`hdmi-core`** — a pure-Verilog HDMI (TMDS) output core for the Sipeed **Tang Nano 20K**
   (Gowin **GW2AR-18**). It generates its own CEA-861 raster, does the TMDS 8b/10b encoding,
   and serialises through Gowin's `OSER10` hard macro. It currently outputs a colour-bar
   test pattern, so it **lights up a TV with no console attached**.
2. **`ppu-capture`** — the PPU bus interposer logic: force `$2000` bit 6 (EXT output
   direction) on the CPU-side PPU register bus, capture the 4-bit pixel colour on
   `EXT0..EXT3`, recover the fifth palette-address bit from VOUT comparators, and resolve
   the 6-bit colour index through a **palette-RAM shadow** rebuilt from `$2006/$2007` writes.
3. **`ppu-hdmi`** — the two combined: capture → 256×240×6 framebuffer (BSRAM) → horizontal
   scaler (4x for 1:1 or 5x for 4:3) → vertical 4x + scanline shading → palette → RGB →
   TMDS → HDMI. It carries **two format variants**: 1080p30 (`ppu_hdmi.gprj`, 4× vertical,
   4-phase scanlines, integer 4×/5× horizontal) and **720p60** (`ppu_hdmi_720p60.gprj`,
   3× vertical, 3-phase scanlines, 960 px 4:3 via integer 3× + a 768→960 "sharp bilinear"
   stage — see `ppu-hdmi/720P60_REPORT.md`).

---

## 2. 当前状态 / Current status

| 功能 / Feature | 状态 / Status | 说明 / Notes |
|---|---|---|
| HDMI 1080p30 输出 / HDMI 1080p30 output | **✅ 真机验证 / Verified on hardware** | 74.25 MHz 像素时钟，371.25 MHz TMDS 位时钟，CEA-861 VIC 16。电视上确认。Confirmed on a TV. |
| HDMI 720p60 输出 / HDMI 720p60 output | **✅ 真机验证 / Verified on hardware** | 同一套时钟，只有光栅换成 VIC 4（1280×720）。电视上确认。Same clocks, CEA-861 VIC 4 raster. Confirmed on a TV. |
| HDMI 1080p60 输出 / HDMI 1080p60 output | **❌ 本器件做不到 / Not achievable on this device** | 需要 742.5 MHz 串行时钟，GW2AR-18 的 rPLL `CLKOUT` 上限 625 MHz。见 `hdmi-core/REPORT.md`。Needs a 742.5 MHz serial clock; the rPLL `CLKOUT` ceiling is 625 MHz. See `hdmi-core/REPORT.md`. |
| PPU 总线抓取 + 调色板影子 / PPU capture + palette shadow | **🧪 仅仿真 / Simulation only** | 61 项检查、7 个场景、0 错误。未上真机。61 checks, 7 scenarios, 0 errors. Never on hardware. |
| PPU → HDMI 集成 / PPU-to-HDMI integration | **🧪 仅仿真 + 时序收敛 / Simulation only, timing closed** | 219,694 项检查、0 错误；GW2AR-18 上各时钟域 0 违规。未烧录。219,694 checks, 0 errors; 0 timing violations in every clock domain on the GW2AR-18. Never programmed. |
| PPU → HDMI **720p60** 变体 / 720p60 variant | **🧪 仅仿真 + 时序收敛 / Simulation only, timing closed** | 190,659 项检查、0 错误（4:3 960×720 与 1:1 1024×720 两种模式并行）；像素域 Fmax 94.564 MHz vs 74.25 MHz 约束，0 违规。未烧录。190,659 checks, 0 errors (4:3 960×720 and 1:1 1024×720 in parallel); pixel-domain Fmax 94.564 MHz vs the 74.25 MHz constraint, 0 violations. Never programmed. |
| 转接板硬件（原理图 / PCB / BOM）/ Interposer hardware | **🚧 仅设计阶段 / Design stage only** | `docs/` 下是作者的设计文档；没有打样、没有装配、没有测试。Design documents only; nothing fabricated, assembled or tested. |
| 真实主机联调 / Real-console bring-up | **⛔ 未开始 / Not started** | 没有任何 2C02 或主机参与过任何验证。No 2C02 and no console has been involved in any verification. |

---

**Credits / 致谢：** 2C02 调色板表取自 [nand2mario/nestang](https://github.com/nand2mario/nestang)
（GPL-3.0），板级引脚号与 CEA-861 光栅常数也对照过同一项目 —— 这也是本仓库整体按 GPL-3.0
发布的原因。PPU 引脚 / EXT 方向与寄存器语义来自 NESdev wiki、emu-russia *BreakingNESWiki*
与 BTTD 的 2C02 参考文档。全部第三方来源见 [NOTICE.md](NOTICE.md) §4。

**Credits:** the 2C02 palette table is reused from
[nand2mario/nestang](https://github.com/nand2mario/nestang) (GPL-3.0), which is why this
repository is licensed GPL-3.0 as a whole. Board pin numbers and the CEA-861 raster constants
were cross-checked against the same project; the PPU pinout, EXT direction and register
semantics come from the NESdev wiki, the emu-russia *BreakingNESWiki* and BTTD's 2C02
reference. Every third-party source is listed in [NOTICE.md](NOTICE.md) §4.

---

## How this was built

AI-assisted RTL and testbenches, with human direction and review. The status
table above states what has been verified on hardware, what only in
simulation, and what not at all — trust it accordingly.

---

## 3. 仓库结构 / Repository layout

```
ppu-capture-hdmi/
├── LICENSE                  GPL-3.0 完整条款 / full GPL-3.0 text
├── README.md                本文件 / this file
├── NOTICE.md                AI 披露 + 验证状态 + 第三方归属 + 商标声明
│                            AI disclosure + verification status + attribution + trademark
├── .gitignore               排除构建产物、码流、授权文件、仿真波形
│                            excludes build output, bitstreams, licences, waveforms
├── docs/                    板级 / 采购 / 接口 / 交接文档（保持原文件名）
│                            board, BOM, interface and handover documents (original filenames)
├── hdmi-core/               纯 HDMI 输出核（真机验证）/ standalone HDMI core (HW verified)
│   ├── rtl/                 hdmi_timing, pattern_gen, tmds_encoder, pll_*, top*
│   ├── constraints/         tn20k.cst + tn20k*.sdc
│   ├── scripts/             build.ps1 (ASCII %TEMP% 镜像构建 / mirror build), build.tcl
│   ├── tn20k_hdmi1080p30.gprj   1080p30 工程 / 1080p30 project
│   ├── tn20k_hdmi720p60.gprj    720p60 工程 / 720p60 project
│   ├── tn20k_hdmi1080p.gprj     1080p60 尝试（不可实现）/ 1080p60 attempt (not achievable)
│   ├── REPORT.md            1080p60 可行性分析 / 1080p60 feasibility analysis
│   └── 720P60_REPORT.md     720p60 变体说明 / 720p60 variant notes
├── ppu-capture/             PPU 转接逻辑（仅仿真）/ PPU interposer logic (sim only)
│   ├── rtl/                 ppu_write_guard, ppu_injector, ppu_palette_shadow,
│   │                        ppu_ext_capture, ppu_pixel_out, ppu_capture_intercept
│   ├── tb/                  tb_ppu_intercept.v
│   ├── sim/                 run.ps1
│   └── REPORT.md            架构与仿真报告 / architecture + simulation report
└── ppu-hdmi/                集成顶层（仅仿真）/ integrated top (sim only)
    ├── rtl/                 ppu_hdmi_top, ppu_video_pipeline, ppu_framebuffer,
    │                        nes_palette, tmds_encoder(流水化), + ppu-capture 的模块
    │                        720p60：ppu_hdmi_top_720p60, ppu_video_pipeline_720p
    ├── tb/                  tb_ppu_hdmi, tb_tmds_pipe_equiv, tmds_encoder_ref,
    │                        tb_ppu_hdmi_720p (720p60)
    ├── constraints/         tn20k_ppu.cst, ppu_hdmi.sdc, ppu_hdmi_720p60.sdc
    ├── scripts/             build.ps1, build.tcl
    ├── sim/                 run.ps1 (1080p30), run_720p.ps1 (720p60)
    ├── ppu_hdmi.gprj        1080p30 工程 / 1080p30 project
    ├── ppu_hdmi_720p60.gprj 720p60 工程 / 720p60 project
    ├── REPORT.md            集成与时序收敛报告 / integration + timing closure report
    └── 720P60_REPORT.md     720p60 变体报告 / 720p60 variant report
```

**码流（`.fs`）、`impl/`、布局布线报告与仿真波形都不入库**，由 `.gitignore` 排除；它们
可以随时由下面的命令重新生成。
**Bitstreams (`.fs`), `impl/`, P&R reports and simulation waveforms are not tracked** — they
are excluded by `.gitignore` and can be regenerated with the commands below.

---

## 4. 硬件要求 / Hardware requirements

**中文**

| 项目 / Item | 要求 / Requirement |
|---|---|
| FPGA 开发板 / FPGA board | Sipeed **Tang Nano 20K**（高云 **GW2AR-LV18QN88C8/I7**，device version **C**，配置码 `gw2ar18c-000`）。用其它 GW2AR-18 板卡时需自行修改 `.cst` 里的引脚。 |
| 时钟 / Clock | 板上 **27 MHz** 晶振，接在**引脚 4**。 |
| HDMI | 3 对 TMDS 数据 + 1 对时钟，差分对在引脚 **33/34（时钟）、35/36、37/38、39/40**；板上已有 HDMI 连接器。 |
| 指示灯 / LEDs | 引脚 **15 / 16**（低有效 / active low）。 |
| 工具链 / Toolchain | 高云 **Gowin EDA V1.9.12**（`C:\Gowin\Gowin_V1.9.12_x64`）。V1.9.11.03 Education 也可用于 `hdmi-core`。 |
| 仿真器 / Simulator | **Icarus Verilog 12.0**（`C:\iverilog\bin`）。 |
| 主机（PPU 部分）/ Console (PPU part) | 使用 **2C02 类 PPU** 的 8 位主机 —— **目前完全没有验证**，且需要先做 `EXT0..EXT3` 隔离，否则可能损坏 PPU。 |

**English**

| Item | Requirement |
|---|---|
| FPGA board | Sipeed **Tang Nano 20K** (Gowin **GW2AR-LV18QN88C8/I7**, device version **C**, config code `gw2ar18c-000`). Any other GW2AR-18 board needs the pin assignments in the `.cst` changed. |
| Clock | On-board **27 MHz** oscillator on **pin 4**. |
| HDMI | 3 TMDS data pairs + 1 clock pair on pins **33/34 (clock), 35/36, 37/38, 39/40**; the board has the HDMI connector. |
| LEDs | Pins **15 / 16** (active low). |
| Toolchain | Gowin **EDA V1.9.12** (`C:\Gowin\Gowin_V1.9.12_x64`). V1.9.11.03 Education also works for `hdmi-core`. |
| Simulator | **Icarus Verilog 12.0** (`C:\iverilog\bin`). |
| Console (PPU part) | An 8-bit console with a **2C02-style PPU** — **completely unverified**, and `EXT0..EXT3` must be isolated first or the PPU can be damaged. |

---

## 5. 构建 / How to build

### 5.1 为什么需要封装脚本 / Why there is a wrapper script

**中文** —— 高云命令行 `gw_sh.exe` **无法处理含非 ASCII 字符的工程路径**。如果本仓库放在
例如 `C:\Users\你\OneDrive\文档\...` 下，`gw_sh` 会把路径变成 `??` 并报：

```
ERROR (SP0002) : Corrupted project file: ".../OneDrive/??/.../impl/gwsynthesis/*.prj"
```

因此 `scripts/build.ps1` 会先把源码（全部是相对路径）镜像到 `%TEMP%` 下的一个纯 ASCII
目录，在那里构建，再把 `impl/` 拷回来。**直接调用 `gw_sh.exe` 也行，只要工程路径是纯 ASCII。**

**English** — Gowin's `gw_sh.exe` **cannot handle a project path containing non-ASCII
characters**. If the repo lives under e.g. `C:\Users\you\OneDrive\文档\...`, `gw_sh` mangles
the path into `??` and fails with the `SP0002` error above. `scripts/build.ps1` therefore
mirrors the (purely relative-path) sources into an ASCII directory under `%TEMP%`, builds
there, and copies `impl/` back. **Calling `gw_sh.exe` directly also works, as long as the
project path is pure ASCII.**

### 5.2 执行策略 / PowerShell execution policy

本机执行策略是 **Restricted**，所以**必须**这样调用（`-ExecutionPolicy Bypass`）：
This host's execution policy is **Restricted**, so scripts **must** be invoked like this:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hdmi-core\scripts\build.ps1 -Project tn20k_hdmi720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64
```

### 5.3 `hdmi-core` —— 已上板验证的两个构建 / the two hardware-verified builds

```powershell
# 720p60（CEA-861 VIC 4）
powershell -NoProfile -ExecutionPolicy Bypass -File .\hdmi-core\scripts\build.ps1 `
    -Project tn20k_hdmi720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64

# 1080p30（CEA-861 VIC 16）
powershell -NoProfile -ExecutionPolicy Bypass -File .\hdmi-core\scripts\build.ps1 `
    -Project tn20k_hdmi1080p30.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64
```

- `-GowinRoot` 不给时默认就是 `C:\Gowin\Gowin_V1.9.12_x64`；换成 Education 版就指过去。
  Without `-GowinRoot` the default is `C:\Gowin\Gowin_V1.9.12_x64`; point it elsewhere for
  the Education build.
- `-Task syn|pnr|all` 可选，默认 `all`（综合 + 布局布线 + 码流）。
  Optional `-Task syn|pnr|all`, default `all` (synthesis + P&R + bitstream).
- `-CleanImpl` 会先删掉 `impl/`（多个 `.gprj` 共用同一个 `impl/`，默认是合并而不是清空）。
  `-CleanImpl` wipes `impl/` first (the `.gprj` variants share one `impl/`; the default
  merges instead of wiping).

**成功的判据 / Success criterion** —— 不是"stdout 里没有 ERROR"，而是：

1. **退出码 0** / exit code 0;
2. `impl/pnr/` 下出现 **`.fs` 码流** / a `.fs` bitstream appears under `impl/pnr/`;
3. 只有两条**已知无害**的警告 / only the two known-benign warnings:
   - `WARN (NL0002)` —— `pattern_gen` 在优化时被扫掉（`u_pat` 的连线没被用到）。
     `pattern_gen` swept during optimisation.
   - `WARN (PR1014)` —— `sys_clk` 用通用布线资源做时钟。
     generic routing resource used to clock `sys_clk`.

另有一条 stderr 噪声 **不算错误**：`alog error: failed to open log file ... sh.log`。
One stderr line is **not** an error: `alog error: failed to open log file ... sh.log`.

**烧录 / Programming**（可选，需自行确认器件与连线 / optional, verify the part and wiring yourself）：

```powershell
# 需要 Gowin Programmer；烧到 SRAM（掉电即丢）/ SRAM, lost on power-off
programmer_cli.exe -f .\hdmi-core\impl\pnr\tn20k_hdmi720p60.fs --device GW2AR-18C
```

### 5.4 `ppu-hdmi`（集成，仅仿真验证）/ integrated, simulation-verified only

```powershell
# 1080p30
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-hdmi\scripts\build.ps1 `
    -GowinRoot C:\Gowin\Gowin_V1.9.12_x64

# 720p60
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-hdmi\scripts\build.ps1 `
    -Project ppu_hdmi_720p60.gprj -GowinRoot C:\Gowin\Gowin_V1.9.12_x64 `
    -Task all -PlaceOption 1 -RouteOption 2 -TimingDriven 1 `
    -GlobalFreq 74.25 -CorrectHold 0 -Replicate 1
```

⚠️ 这个构建**通过了时序收敛但没有上过板**。`tn20k_ppu.cst` 里所有 PPU 侧端口**只有电气
属性、没有引脚位置**（还没有转接板，高云会自动布局）。
This build **closes timing but has never been on a board**. Every PPU-side port in
`tn20k_ppu.cst` has **electrical attributes only, no pin locations** (there is no interposer
board yet; Gowin auto-places them).

### 5.5 不用 PowerShell 的话 / Without PowerShell

`scripts/build.tcl` 是真正的构建脚本，可以直接交给 `gw_sh.exe`：
`scripts/build.tcl` is the actual build script and can be handed to `gw_sh.exe` directly:

```powershell
$env:GOWIN_HOME = "C:\Gowin\Gowin_V1.9.12_x64"
cd C:\work\ascii-path\hdmi-core        # 必须是纯 ASCII 路径 / must be pure ASCII
& "$env:GOWIN_HOME\IDE\bin\gw_sh.exe" scripts\build.tcl all tn20k_hdmi720p60.gprj
```

---

## 6. 仿真 / How to run the simulations

两个仿真都必须用 `-ExecutionPolicy Bypass` 调用（脚本同样会把源码复制到 ASCII 临时目录）。
Both simulations must be launched with `-ExecutionPolicy Bypass` (the scripts also mirror
the sources into an ASCII temp directory).

### 6.1 `ppu-capture` —— 61 项检查 / 61 checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-capture\sim\run.ps1
```

期望输出 / expected output:

```
================================================================
 SUMMARY: 61 checks, 0 errors
 RESULT: ALL SEVEN SCENARIOS PASS (EXT_OUT_BIT=6)
================================================================
```

七个场景覆盖：`$2000/$2001` 透传、FPGA 注入、写守卫、注入时序与建立/保持裕量、
`$2006/$2007` 调色板影子写与 +1/+32 自增与镜像、`EXT0..EXT3 + ext4` 像素抓取与查表、
`$2006` 写顺序。加 `-RunBit2` 可复现任务书原始的 `EXT_OUT_BIT=2` 变体（**预期失败**，
因为强制 bit 2 会破坏 VRAM 增量）。
The seven scenarios cover `$2000/$2001` pass-through, FPGA injection, the write guard,
injection timing and setup/hold margins, `$2006/$2007` palette writes with +1/+32
increment and mirroring, `EXT0..EXT3 + ext4` capture and lookup, and `$2006` write ordering.
`-RunBit2` reproduces the original `EXT_OUT_BIT=2` variant (**expected to fail**, because
forcing bit 2 corrupts the VRAM increment).

### 6.2 `ppu-hdmi` —— 219,694 项检查 / 219,694 checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-hdmi\sim\run.ps1
# 需要波形时 / for a waveform:
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-hdmi\sim\run.ps1 -Vcd
```

期望输出 / expected output:

```
 framebuffer entry checks : 61440
 swept pixel checks       : 96790
 named point checks       : 24
 total checks             : 219694
 errors                   : 0
 RESULT: PASS
```

### 6.2b `ppu-hdmi` 720p60 —— 190,659 项检查 / 190,659 checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ppu-hdmi\sim\run_720p.ps1
```

期望输出 / expected output:

```
 framebuffer entry checks : 61440
 swept pixel checks       : 67740
 stage-A / geometry checks: 4
 named point checks       : 27
 total checks             : 190659
 errors                   : 0
 RESULT: PASS
```

两种缩放模式（4:3 960×720 / 1:1 1024×720）在同一个 testbench 里并行跑完一整个
1650×750 帧；完整输出见 `ppu-hdmi/sim/simulation_output_720p.txt`。
Both scaling modes (4:3 960×720 / 1:1 1024×720) run in parallel through one complete
1650×750 frame; full output in `ppu-hdmi/sim/simulation_output_720p.txt`.

### 6.3 TMDS 编码器流水线等价性 / TMDS encoder pipeline equivalence（手动 / manual）

```powershell
cd .\ppu-hdmi\tb
C:\iverilog\bin\iverilog.exe -g2005 -o equiv tb_tmds_pipe_equiv.v tmds_encoder_ref.v ..\rtl\tmds_encoder.v
C:\iverilog\bin\vvp.exe equiv
```

期望 / expected: `cycles compared : 200000`、`mismatches : 0`、`RESULT: PASS`。

---

## 7. 编码注意事项 / Encoding notes

本仓库的注释是**中文 + 英文双语**的。实测结论（细节与证据见 [`NOTICE.md`](NOTICE.md) §3）：
The comments here are **bilingual (Chinese + English)**. Measured conclusions (details and
evidence in [`NOTICE.md`](NOTICE.md) §3):

| 文件 / Files | 编码 / Encoding | 中文注释是否安全 / Chinese comments safe? |
|---|---|---|
| `*.v`, `*.cst`, `*.sdc`, `*.tcl` | UTF-8 **无 BOM** / UTF-8 **without BOM** | ✅ 是 / yes |
| `*.ps1` | UTF-8 **带 BOM** / UTF-8 **with BOM** | ✅ 是（**无 BOM 会乱码**）/ yes (**mojibake without BOM**) |

⚠️ **`.cst` / `.sdc` 千万不要存成带 BOM 的 UTF-8**：会得到
`ERROR (CT2000) : ... 'syntax error' near token '?'` 并导致构建失败。
⚠️ **Never save `.cst` / `.sdc` as UTF-8 with a BOM**: you get
`ERROR (CT2000) : ... 'syntax error' near token '?'` and the build fails.

---

## 8. 许可证 / Licence

**中文**

本仓库以 **GNU General Public License v3.0（或更新版本）** 发布，完整条款见
[`LICENSE`](LICENSE)。之所以是 GPL-3.0，是因为 `ppu-hdmi/rtl/nes_palette.v` 中的
2C02 调色板表复用自 **GPL-3.0** 的 [nand2mario/nestang](https://github.com/nand2mario/nestang)
（`src/nes2hdmi.sv`），其数值来源为 NESdev wiki 的
[PPU palettes](https://www.nesdev.org/wiki/PPU_palettes) 页面。归属细节见
[`NOTICE.md`](NOTICE.md) §4。

**English**

This repository is released under the **GNU General Public License v3.0 (or later)**;
full terms in [`LICENSE`](LICENSE). It is GPL-3.0 because the 2C02 palette table in
`ppu-hdmi/rtl/nes_palette.v` is reused from the **GPL-3.0** project
[nand2mario/nestang](https://github.com/nand2mario/nestang) (`src/nes2hdmi.sv`), whose
values come from the NESdev wiki [PPU palettes](https://www.nesdev.org/wiki/PPU_palettes)
page. Attribution details in [`NOTICE.md`](NOTICE.md) §4.

---

*Unofficial hobby project — not affiliated with Nintendo.*
