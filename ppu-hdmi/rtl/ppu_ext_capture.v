// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_ext_capture.v
//
// 在 PPU 像素时钟域里寄存 2C02 的 EXT 总线与比较器恢复的视频时序信号。
// Registers the 2C02 EXT bus and the comparator-derived video timing signals
// in the PPU pixel-clock domain.
//
// 当 $2000 的 bit 6 = 1（主 / 输出模式）时，2C02 的 EXT0..EXT3 引脚承载
// 4 位像素颜色。调色板地址的第 5 位（背景 / 精灵）不在 EXT 上；它必须由
// 外部比较器从 VOUT 恢复，在这里以 ext4_bg_sprite_i 呈现（1 = 精灵，
// 0 = 背景）。hsync_i、vsync_i 和 blank_i 同样是比较器输出，而不是 PPU 引脚。
// The 2C02 EXT0..EXT3 pins carry the 4-bit pixel colour when $2000 bit 6 = 1
// (master/output).  The fifth palette-address bit (background vs sprite) is
// not on EXT; it must be recovered from VOUT by external comparators and is
// presented here as ext4_bg_sprite_i (1 = sprite, 0 = background).  hsync_i,
// vsync_i and blank_i are likewise comparator outputs, not PPU pins.
//
// 本模块不对模拟比较器、电平转换或 VOUT 分压建模 —— 那些属于板级硬件。
// 它只定义干净的数字接口，并在像素时钟上寄存。
// This module does NOT model the analog comparator, level shifting, or the
// VOUT slice.  Those are board-level hardware.  It only defines the clean
// digital interface and registers it on the pixel clock.
//
// 注意：这里只用了一级寄存器。在真实硬件上，比较器输出相对 PPU 是异步的，
// 应当做同步（通常两级触发器）和/或用一个根据实测视频时序选定的时钟相位
// 去采样。这留给板级 / 约束阶段处理；见 REPORT.md。
// NOTE: one register stage is used here.  On real hardware the comparator
// outputs are asynchronous to the PPU and should be synchronized (typically
// two flops) and/or sampled with a clock phase chosen from the measured video
// timing.  That is left as a board-level/constraint task; see REPORT.md.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_ext_capture (
    input  wire       pix_clk,      // PPU 点时钟（标称 5.369 MHz）/ PPU dot clock (5.369 MHz nominal)
    input  wire       rst_n,

    input  wire [3:0] ext_i,        // EXT0..EXT3，4 位像素颜色 / EXT0..EXT3, 4-bit pixel colour
    input  wire       ext4_bg_sprite_i, // 1 = 精灵半区（$3F10..），0 = 背景 / 1 = sprite half ($3F10..), 0 = BG
    input  wire       hsync_i,
    input  wire       vsync_i,
    input  wire       blank_i,

    output reg  [3:0] ext_pixel,
    output reg        ext4_bg_sprite,
    output reg        hsync,
    output reg        vsync,
    output reg        blank
);

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_pixel       <= 4'h0;
            ext4_bg_sprite  <= 1'b0;
            hsync           <= 1'b0;
            vsync           <= 1'b0;
            blank           <= 1'b1;
        end else begin
            ext_pixel       <= ext_i;
            ext4_bg_sprite  <= ext4_bg_sprite_i;
            hsync           <= hsync_i;
            vsync           <= vsync_i;
            blank           <= blank_i;
        end
    end

endmodule

`default_nettype wire
