// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_write_guard.v
//
// 透明的 CPU->PPU 写通路，带一个可选的、单比特的写守卫。
// Transparent CPU->PPU write path with an optional, single-bit write guard.
//
// 当 capture_en 为高时，CPU 对 PPU 寄存器 $2000 的每次写入都会在到达 2C02
// 之前把 EXT_OUT_BIT 强制置 1。其它位、其它寄存器以及所有读周期都原样
// 透传。被守卫后的值同时保存在 ctrl_shadow 里，以便之后的自主注入能保留
// 游戏设置的其它 PPUCTRL 位。
// When capture_en is high, every CPU write to PPU register $2000 has the
// EXT_OUT_BIT forced to 1 before it reaches the 2C02.  All other bits, all
// other registers, and all read cycles pass through untouched.  The guarded
// value is also kept in ctrl_shadow so that a later autonomous injection can
// preserve the game's other PPUCTRL bits.
//
// 关于 $2000 控制位的说明
// NOTE ON THE $2000 CONTROL BIT
//   任务书把 $2000 的 bit 2 叫作 "主/从选择"。但在标准 Ricoh 2C02 上，
//   $2000 的 bit 2 是 VRAM 地址增量，选择 EXT 引脚方向的是 bit 6：
//   The task statement called $2000 bit 2 the "master/slave select".  On a
//   standard Ricoh 2C02, $2000 bit 2 is the VRAM address increment and $2000
//   bit 6 selects the EXT-pin direction:
//       bit 6 = 0 : 从模式 / 输入（从 EXT0..EXT3 读颜色）
//       bit 6 = 0 : slave / input  (read colour from EXT0..EXT3)
//       bit 6 = 1 : 主模式 / 输出（在 EXT0..EXT3 上驱动颜色）
//       bit 6 = 1 : master / output (drive colour on EXT0..EXT3)
//   因此 EXT_OUT_BIT 是 6，被强制写入的值是 1。旧名字 SLAVE_BIT 有误导性：
//   它描述的是这个位，而不是它的值。
//   EXT_OUT_BIT is therefore 6 and the value forced is 1.  The old name
//   SLAVE_BIT was misleading; it described the bit, not the value.
//
// 资料来源：BreakingNESWiki 的 PPU pads（"0: PPU slave mode, 1: PPU master
// mode"）、BreakingNESWiki 的 MUX（从模式 $2000[6]=0）、以及 nes-ppu 的 API
// 文档（"0: background read from EXT; 1: color output on EXT"）。见 REPORT.md。
// Sources: BreakingNESWiki PPU pads ("0: PPU slave mode, 1: PPU master mode"),
// BreakingNESWiki MUX (slave mode $2000[6]=0), and the nes-ppu API docs
// ("0: background read from EXT; 1: color output on EXT").  See REPORT.md.
//
// 推导 / 归属说明：
// Derivation / attribution:
//   $2000 各位的含义已与 nand2mario/nestang（GPL-3.0）交叉核对，
//   参考 src/ppu.v 中 module PPU 的 "case (ain) 0:" 以及 module LoopyGen。
//   本文件没有逐字复制任何 nestang 源码。
//   The $2000 bit meanings were cross-checked against nand2mario/nestang
//   (GPL-3.0), src/ppu.v, module PPU, "case (ain) 0:" and module LoopyGen.
//   No nestang source text is copied verbatim into this file.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_write_guard #(
    parameter integer EXT_OUT_BIT = 6
) (
    input  wire       clk,
    input  wire       rst_n,

    // CPU 侧的 PPU 寄存器总线（已译码到 $2000-$3FFF）
    // CPU-side PPU register bus (already decoded to $2000-$3FFF)
    input  wire       cpu_cs_n,     // 低有效 / active low
    input  wire       cpu_rw,       // 1 = 读，0 = 写（2C02 的 R/W 极性）/ 1 = read, 0 = write (2C02 R/W polarity)
    input  wire [2:0] cpu_a,        // PPU 寄存器地址 A0..A2 / PPU register address A0..A2
    input  wire [7:0] cpu_d_in,     // 进入转接板的 CPU 数据 / CPU data into the interposer

    input  wire       capture_en,   // 1 = 在 $2000 写上强制 EXT_OUT_BIT / 1 = force EXT_OUT_BIT on $2000 writes

    output reg  [7:0] ctrl_shadow,  // PPU 将看到的最后一个 $2000 值 / last $2000 value that the PPU will see
    output wire       cpu_write,    // 合格的 CPU 写选通（电平）/ qualified CPU write strobe (level)
    output wire [7:0] ppu_write_data,
    output wire       ext_out_bit_shadow
);

    // 所选控制位的独热掩码。EXT_OUT_BIT 取值 0..7。
    // One-hot mask for the selected control bit.  EXT_OUT_BIT is 0..7.
    wire [7:0] ext_out_mask = (8'h01 << EXT_OUT_BIT);

    assign cpu_write       = ~cpu_cs_n & ~cpu_rw;
    wire   ctrl_write      = cpu_write & (cpu_a == 3'b000);

    // PPU 侧字节。守卫是纯组合逻辑：它不给 CPU 写增加任何时钟延迟，
    // 因此正常的 bus setup/hold 得以保持。
    // The PPU-side byte.  The guard is purely combinational: it adds no clock
    // of latency to a CPU write, so the normal bus setup/hold is preserved.
    assign ppu_write_data  = (capture_en & ctrl_write)
                           ? (cpu_d_in | ext_out_mask)
                           : cpu_d_in;

    assign ext_out_bit_shadow = ctrl_shadow[EXT_OUT_BIT];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_shadow <= 8'h00;
        end else if (ctrl_write) begin
            // 保存 PPU 实际得到的那份值，而不是 CPU 的原始值。后续注入必须
            // 保留的就是这个值。
            // Keep the value the PPU is actually being given, not the raw CPU
            // value.  This is the value a later injection must preserve.
            ctrl_shadow <= capture_en ? (cpu_d_in | ext_out_mask) : cpu_d_in;
        end
    end

endmodule

`default_nettype wire
