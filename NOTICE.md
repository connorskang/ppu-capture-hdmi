# 声明、归属与免责 / Notices, Attribution and Disclaimers

本文件是 `ppu-capture-hdmi` 仓库的法律与出处说明。请与 `README.md`、`LICENSE` 一起阅读。
This file is the legal and provenance notice for the `ppu-capture-hdmi` repository.
Read it together with `README.md` and `LICENSE`.

---

## 1. AI 生成披露 / AI-Generation Disclosure

**中文**

本仓库中的代码是**在 AI 辅助下生成的**。具体地说：

- 绝大部分 RTL（`rtl/*.v`）、testbench（`tb/*.v`）、构建与仿真脚本
  （`scripts/*.ps1`、`scripts/*.tcl`、`sim/*.ps1`）、约束文件
  （`constraints/*.cst`、`constraints/*.sdc`）以及其中的**双语注释**，都是由一个
  **AI 编程代理**（AI coding agent）生成的。
- **人类作者**提供了全部方向：硬件平台与器件选择、目标分辨率与时序、
  PPU 抓取架构的取舍、对 AI 输出的逐轮审查与纠错、以及在真实硬件上的上板验证。
- AI 生成的代码**不等于正确**。本仓库中出现的每一处"已验证"结论，都是人类作者
  在实际工具链或真实板卡上跑出来的结果，而不是 AI 的断言。

**English**

The code in this repository was **produced with AI assistance**. Specifically:

- Essentially all of the RTL (`rtl/*.v`), the testbenches (`tb/*.v`), the build and
  simulation scripts (`scripts/*.ps1`, `scripts/*.tcl`, `sim/*.ps1`), the constraint
  files (`constraints/*.cst`, `constraints/*.sdc`) and the **bilingual comments**
  in them were produced by an **AI coding agent**.
- The **human author** supplied all of the direction: hardware platform and device
  choice, target resolutions and timing, the PPU-capture architecture trade-offs,
  round-by-round review and correction of the AI output, and the on-hardware
  verification.
- AI-generated code is **not automatically correct**. Every "verified" claim in this
  repository comes from the human author actually running the real toolchain or the
  real board — not from an AI assertion.

每个源文件顶部都有这一行提示 / Every source file starts with this marker:

```
// AI-assisted; see NOTICE.md
```

---

## 2. 验证状态：哪些跑过真机，哪些只是仿真 / Verification Status

这一节是严格的。请按"证据等级"理解本仓库的一切结论。
This section is strict. Read every claim in this repository in terms of the evidence
level given here.

| 部分 / Part | 状态 / Status | 证据 / Evidence |
|---|---|---|
| `hdmi-core` — 1080p30 与 720p60 HDMI 输出 / 1080p30 and 720p60 HDMI output | **真机验证 / VERIFIED ON HARDWARE** | 综合、布局布线、生成码流并烧录到 Tang Nano 20K；在真实电视机上看到稳定画面（1080p30 与 720p60 两种模式）。Synthesised, placed, routed, programmed into a Tang Nano 20K, and confirmed on a real TV in both 1080p30 and 720p60 modes. |
| `hdmi-core` — 1080p60 变体 / 1080p60 variant | **不可实现（已记录的否定结果）/ NOT ACHIEVABLE (documented negative result)** | GW2AR-18 的 rPLL `CLKOUT` 上限 625 MHz，而 1080p60 需要 742.5 MHz。见 `hdmi-core/REPORT.md`。The GW2AR-18 rPLL `CLKOUT` ceiling is 625 MHz; 1080p60 needs 742.5 MHz. See `hdmi-core/REPORT.md`. |
| `ppu-capture` — PPU 总线转接与调色板影子 / PPU bus interposer + palette shadow | **仅仿真验证 / SIMULATION ONLY** | Icarus Verilog，7 个场景、61 项检查、0 错误。**从未接触任何真实主机或 2C02。** Icarus Verilog, 7 scenarios, 61 checks, 0 errors. **Never connected to any real console or 2C02.** |
| `ppu-hdmi` — PPU → HDMI 集成 / PPU-to-HDMI integration | **仅仿真验证 + 时序收敛 / SIMULATION ONLY, TIMING CLOSED** | Icarus Verilog，219,694 项检查、0 错误；针对 GW2AR-18 完成综合与布局布线，各时钟域 0 违规。**从未烧录、从未上板、从未输出过画面。** Icarus Verilog, 219,694 checks, 0 errors; synthesised and P&R'd for the GW2AR-18 with 0 violations in every clock domain. **Never programmed, never put on a board, never produced a picture.** |
| 硬件设计（转接板原理图 / PCB / BOM）/ Hardware design (interposer schematic / PCB / BOM) | **仅设计阶段 / DESIGN STAGE ONLY** | `docs/` 下的文档是作者自己的设计工作；没有打样、没有装配、没有测试。The documents under `docs/` are the author's own design work; nothing was fabricated, assembled or tested. |

**一句话总结 / One-line summary:** HDMI 输出这段在电视上看到过；PPU 相关的部分**一行都没有上过真机**。
The HDMI output path has been seen on a TV; **nothing PPU-related has ever touched real hardware.**

---

## 3. 编码与工具链兼容性实测（中文注释）/ Encoding and Toolchain Compatibility

本仓库的注释是中文 + 英文双语的。为了确认非 ASCII 字符不会破坏工具链，下表每一项都做了
**实测**，不是推测。
The comments in this repository are bilingual (Chinese + English). Every row below was
**empirically tested**, not assumed.

| 文件类型 / File type | 容忍中文？ / Tolerates Chinese? | 编码要求 / Encoding | 实测证据 / Evidence |
|---|---|---|---|
| `*.v`（RTL、testbench） | **是 / YES** | UTF-8 **无 BOM** / UTF-8 without BOM | Icarus Verilog 12.0 编译通过并跑完全部仿真；高云 GowinSynthesis 综合通过并生成码流。Compiled by Icarus Verilog 12.0 and accepted by Gowin synthesis in a full build. |
| `*.cst`（物理约束） | **是，但绝对不能带 BOM** / **YES, but never with a BOM** | UTF-8 **无 BOM** / UTF-8 without BOM | 无 BOM：`Physical Constraint parsed completed`，构建 exit 0。带 BOM：`ERROR (CT2000) : "...\tn20k.cst":1 \| 'syntax error' near token '?'`，构建 exit 1。Without BOM the constraints parse and the build exits 0; with a BOM the build fails with that exact CT2000 error. |
| `*.sdc`（时序约束） | **是，但绝对不能带 BOM** / **YES, but never with a BOM** | UTF-8 **无 BOM** / UTF-8 without BOM | 与 `.cst` 同一套约束解析器；本次构建中带中文注释的 `*.sdc` 正常解析并参与时序分析。Same constraint parser as `.cst`; the Chinese-commented `.sdc` files parsed and were used by STA in the verification build. |
| `*.ps1`（PowerShell） | **是，但必须带 BOM** / **YES, but only with a BOM** | UTF-8 **带 BOM** / UTF-8 **with** BOM | 无 BOM 时本机 PowerShell 按 ANSI 解码，中文变成乱码（`涓枃` 之类），字符串内容被破坏；带 BOM 时输出正确。本仓库所有 `.ps1` 都保存为 **UTF-8 with BOM**。Without a BOM this host's PowerShell decodes as ANSI and the Chinese turns into mojibake, corrupting string literals; with a BOM it is correct. Every `.ps1` here is UTF-8 **with** BOM. |
| `*.tcl`（gw_sh 脚本） | **是 / YES** | UTF-8 无 BOM / UTF-8 without BOM | `gw_sh.exe` 执行带中文注释的 TCL 脚本 exit 0，无语法错误。唯一现象是 `puts` 到控制台的中文显示为 `?`（控制台代码页问题，纯外观）。`gw_sh.exe` runs a Chinese-commented TCL script with exit 0 and no syntax error; the only artefact is that Chinese emitted by `puts` shows as `?` on the console (code-page issue, cosmetic). |

因此 / Therefore:

- **Verilog、约束、TCL 文件**：UTF-8 无 BOM，注释双语。
- **PowerShell 文件**：UTF-8 **带 BOM**，注释双语。
- 仓库里**没有**任何靠"改成纯英文"来绕过编码问题的文件 —— 所有文件都保留了中文注释。

---

## 4. 第三方归属 / Third-party Attribution

### 4.1 nand2mario/nestang — GPL-3.0

**中文**

- 仓库：<https://github.com/nand2mario/nestang>，许可证 **GPL-3.0**。
- 本仓库使用的 `2C02` 调色板 RGB 查找表（`ppu-hdmi/rtl/nes_palette.v`）取自该项目的
  `src/nes2hdmi.sv`，其数值来源为 NESdev wiki 的 *PPU palettes* 页面
  （<https://www.nesdev.org/wiki/PPU_palettes>）。复用该表已获本仓库作者确认。
- Tang Nano 20K 的板级引脚号（27 MHz 晶振 = 引脚 4、TMDS 差分对 33/34–39/40、
  LED 15/16）同样参照该项目的 `nano20k.cst`，并已在真实板卡上核对。
- 由于上述复用，**本仓库整体按 GPL-3.0（或更新版本）发布**。完整条款见 `LICENSE`。
- 除调色板表数据与引脚号事实外，本仓库没有逐字复制 nestang 的源码。

**English**

- Repository: <https://github.com/nand2mario/nestang>, licensed **GPL-3.0**.
- The `2C02` palette RGB lookup table used here (`ppu-hdmi/rtl/nes_palette.v`) is taken
  from that project's `src/nes2hdmi.sv`, whose values in turn come from the NESdev wiki
  *PPU palettes* page (<https://www.nesdev.org/wiki/PPU_palettes>). Reuse of this table
  was confirmed by this repository's author.
- The Tang Nano 20K board pin numbers (27 MHz oscillator = pin 4, TMDS pairs
  33/34–39/40, LEDs 15/16) were also cross-checked against that project's
  `nano20k.cst` and verified on a real board.
- **As a consequence, this repository as a whole is released under GPL-3.0
  (or later).** Full terms in `LICENSE`.
- Apart from the palette table data and those pin-number facts, no nestang source text
  was copied verbatim into this repository.

### 4.2 其他引用 / Other references

**中文**

- 高云半导体（Gowin）的 `rPLL` / `CLKDIV` / `OSER10` / `ELVDS_OBUF` 原语用法，参照官方
  《Primitive User Guide》(SUG283) 与器件数据手册的**描述性引用**，未复制任何文档正文。
- `2C02` / `2A03` 的寄存器位含义（如 `$2000` bit 6 = EXT 输出方向）参照
  BreakingNESWiki 与 nes-ppu API 文档的公开描述。
- 所有第三方数据手册数值均为**引用**，不是转载。

**English**

- Gowin `rPLL` / `CLKDIV` / `OSER10` / `ELVDS_OBUF` primitive usage is a **descriptive
  reference** to the official *Primitive User Guide* (SUG283) and the device datasheet;
  no document text is reproduced.
- `2C02` / `2A03` register-bit meanings (e.g. `$2000` bit 6 = EXT output direction) follow
  public descriptions in the BreakingNESWiki and the nes-ppu API documentation.
- All third-party datasheet values are **cited**, not reproduced.

---

## 5. 硬件设计归属 / Hardware Design Attribution

**中文**

`docs/` 下的原理图、PCB 几何、接口定义、BOM 与采购清单（`INTERCEPT-BOARD.md`、
`INTERCEPT-BOM.md`、`PCB-GEOMETRY.md`、`INTERFACES.md`、`采购-最终版.md` 等）是
**作者本人的设计工作**，与 AI 生成无关的部分以作者为准。文档中引用的任何第三方
数据手册数值都是引用，未整段复制。

**English**

The schematic, PCB geometry, interface definitions, BOM and purchasing documents under
`docs/` (`INTERCEPT-BOARD.md`, `INTERCEPT-BOM.md`, `PCB-GEOMETRY.md`, `INTERFACES.md`,
`采购-最终版.md`, …) are **the author's own design work**. Any third-party datasheet
values cited in them are referenced, not reproduced.

---

## 6. 仓库中不包含什么 / What This Repository Does NOT Contain

**中文**

- **没有任何 ROM、BIOS 转储或受版权保护的主机代码/数据。** 仿真图案是 testbench 里
  现算出来的，不是从游戏或 ROM 里取的。
- **没有码流（`.fs`）**、没有布局布线产物、没有授权文件（`*.lic`）。这些都由
  `.gitignore` 排除。
- 没有厂商的 EDA 授权文件；`gwlicense.ini` 属于本机安装，永不发布。

**English**

- **No ROM images, no BIOS dumps, no copyrighted console code or data.** The simulation
  patterns are generated inside the testbenches, not taken from a game or a ROM.
- **No bitstreams (`.fs`)**, no place-and-route output, no licence files (`*.lic`).
  These are excluded by `.gitignore`.
- No vendor EDA licence file. `gwlicense.ini` belongs to a local installation and is
  never published.

---

## 7. 风险自负 / Use At Your Own Risk

**中文**

- 本仓库按 **GPL-3.0** 的免责条款提供，**不附带任何担保**，包括适销性与特定用途适用性。
- **硬件风险是真实的**：在原始主机上，PPU 的 `EXT0..EXT3` 引脚是接地的。在它们仍然
  接地时把这些引脚切换成输出去驱动，**可能损坏 PPU**。在使能输出模式之前，必须先用
  转接板/插座/割线把 `EXT0..EXT3` 与主机隔离。详见 `ppu-capture/REPORT.md`。
- 上板前请自行确认电平、供电与引脚，作者不对任何设备损坏、数据丢失或人身伤害负责。
- PPU 相关代码**从未在真实主机上验证过**。请把它当作研究原型，而不是成品。

**English**

- This repository is provided under **GPL-3.0**, **without any warranty**, including
  merchantability or fitness for a particular purpose.
- **The hardware risk is real**: on a stock console the PPU's `EXT0..EXT3` pins are tied
  to ground. Driving them as outputs while they are still grounded **can damage the PPU**.
  Isolate `EXT0..EXT3` from the console (interposer board, socket, or trace cut) before
  enabling output mode. See `ppu-capture/REPORT.md`.
- Verify levels, power and pinout yourself before connecting anything. The author accepts
  no liability for damaged hardware, lost data, or injury.
- Nothing PPU-related has ever been validated on a real console. Treat it as a research
  prototype, not a finished product.

---

## 8. 商标 / Trademarks

本项目的名称、描述与代码中出现的产品名和芯片型号，仅用于说明兼容性。
"Famicom"、"NES"、"Nintendo" 等是其各自权利人的商标，本项目与其权利人无关联。

Product names and chip designations appear here only to describe compatibility.
"Famicom", "NES" and "Nintendo" are trademarks of their respective owners;
this project is not affiliated with them.
