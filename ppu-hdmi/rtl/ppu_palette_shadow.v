// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_palette_shadow.v
//
// 2C02 调色板 RAM 的 32 x 6 位影子，通过监听 CPU 对 $2006（地址）和
// $2007（数据）的写来重建。
// 32 x 6-bit shadow of the 2C02 palette RAM, reconstructed from CPU writes to
// $2006 (address) and $2007 (data).
//
// 实现的行为：
// Behaviour implemented:
//   * $2006 是两次写完成的地址锁存：第一次写设置 A13..A8，第二次写设置
//     A7..A0。PPU 地址保持为一个 14 位寄存器。
//   * $2006 is a two-write address latch: first write sets A13..A8, second
//     write sets A7..A0.  The PPU address is kept as a 14-bit register.
//   * 当当前地址落在 $3F00-$3F1F 时，$2007 的写入会把低 6 位写进影子；
//     其它地址的写被忽略（但地址仍然自增，与 PPU 行为一致）。
//   * $2007 writes the low 6 bits into the shadow when the current address is
//     in $3F00-$3F1F; writes elsewhere are ignored (the address still
//     auto-increments, as on the PPU).
//   * $2007 的自增是 +1 或 +32，由 $2000 的 bit 2 选择。
//   * the $2007 auto-increment is +1 or +32, selected by $2000 bit 2.
//   * $2001 的 bit 7..5（强调色 emphasis）与 bit 0（灰度 grayscale）被记录下来，
//     供后续 RGB 级使用。
//   * $2001 bits 7..5 (emphasis) and bit 0 (grayscale) are captured for a
//     later RGB stage.
//   * 四个调色板镜像地址 $3F10/$3F14/$3F18/$3F1C 在读写时都映射到
//     $3F00/$3F04/$3F08/$3F0C。这是标准 NES 行为，但在 REPORT.md 中标记为
//     一个假设。
//   * the four palette mirror addresses $3F10/$3F14/$3F18/$3F1C are mapped to
//     $3F00/$3F04/$3F08/$3F0C on both write and read.  This is standard NES
//     behaviour but is marked as an assumption in REPORT.md.
//
// PPU 地址寄存器是整个 PPU 共用的；本模块只需要其中足够识别调色板写的部分。
// 它不对 VRAM 访问建模，也不对渲染期间地址寄存器的用途建模。
// The PPU address register is shared by the whole PPU; this module only needs
// enough of it to identify palette writes.  It does not model VRAM accesses or
// the rendering-time use of the address register.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_palette_shadow (
    input  wire       clk,
    input  wire       rst_n,

    // CPU 侧的 PPU 寄存器总线 / CPU-side PPU register bus
    input  wire       cpu_cs_n,
    input  wire       cpu_rw,
    input  wire [2:0] cpu_a,
    input  wire [7:0] cpu_d_in,

    // 来自 ppu_write_guard 的 $2000 影子（bit 2 选择 +1/+32）
    // $2000 shadow from ppu_write_guard (bit 2 selects +1/+32)
    input  wire [7:0] ctrl_shadow,

    // 记录下来的 $2001 位 / Captured $2001 bits
    output reg  [7:0] mask_shadow,
    output wire [2:0] emphasis,
    output wire       grayscale,

    // 给像素输出级的调色板读端口 / Palette read port for the pixel-output stage
    input  wire [4:0] pal_addr_i,
    output wire [5:0] pal_data_o
);

    reg [5:0] pal_mem [0:31];
    reg [13:0] ppu_addr;
    reg        addr_latch;      // 0 = 等待 $2006 高字节，1 = 等待低字节 / 0 = expect $2006 high byte, 1 = low byte
    reg        wr_seen;

    integer i;

    wire cpu_write = ~cpu_cs_n & ~cpu_rw;

    // 仅在 $3F00-$3F1F 范围。/ $3F00-$3F1F only.
    wire in_palette_range = (ppu_addr[13:8] == 6'h3F) &&
                            (ppu_addr[7:5]  == 3'b000);

    // 四个通用背景色镜像地址。/ The four universal-backdrop mirrors.
    function [4:0] mirror_palette;
        input [4:0] a;
        begin
            if (a[4] && (a[1:0] == 2'b00))
                mirror_palette = {1'b0, a[3:0]};
            else
                mirror_palette = a;
        end
    endfunction

    wire [4:0] pal_wr_addr = mirror_palette(ppu_addr[4:0]);
    wire [4:0] pal_rd_addr = mirror_palette(pal_addr_i);

    assign pal_data_o = pal_mem[pal_rd_addr];

    assign emphasis  = mask_shadow[7:5];
    assign grayscale = mask_shadow[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ppu_addr  <= 14'h0000;
            addr_latch <= 1'b0;
            wr_seen   <= 1'b0;
            mask_shadow <= 8'h00;
            for (i = 0; i < 32; i = i + 1)
                pal_mem[i] <= 6'h00;
        end else begin
            if (!cpu_write) begin
                wr_seen <= 1'b0;
            end else if (!wr_seen) begin
                // 每次 CPU 总线拉低只算一次寄存器写。
                // One register write per CPU bus assertion.
                wr_seen <= 1'b1;

                case (cpu_a)
                    3'b001: begin
                        // $2001：强调色 + 灰度 / $2001: emphasis + grayscale
                        mask_shadow <= cpu_d_in;
                    end

                    3'b110: begin
                        // $2006：先高字节，再低字节。/ $2006: high byte first, then low byte.
                        if (!addr_latch) begin
                            ppu_addr[13:8] <= cpu_d_in[5:0];
                            addr_latch     <= 1'b1;
                        end else begin
                            ppu_addr[7:0]  <= cpu_d_in;
                            addr_latch     <= 1'b0;
                        end
                    end

                    3'b111: begin
                        // $2007：写调色板，然后自增。/ $2007: palette write, then auto-increment.
                        if (in_palette_range)
                            pal_mem[pal_wr_addr] <= cpu_d_in[5:0];

                        ppu_addr <= ppu_addr + (ctrl_shadow[2] ? 14'd32 : 14'd1);
                    end

                    default: begin
                        // $2000/$2002-$2005：无调色板动作。/ $2000/$2002-$2005: no palette action.
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
