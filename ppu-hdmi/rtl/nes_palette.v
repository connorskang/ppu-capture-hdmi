// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// nes_palette.v
//
// 64 x 24 位 RGB 查找表，把 2C02 调色板表项（即 ppu_pixel_out 产生的 6 位
// NES 颜色索引）转成 RGB。
// 64 x 24-bit RGB lookup for the 2C02 palette entry (the 6-bit NES colour index
// that ppu_pixel_out produces).
//
// 本表取自 nand2mario/nestang（GPL-3.0），
// src/nes2hdmi.sv 中的 "2C02 palette: https://www.nesdev.org/wiki/PPU_palettes"。
// 复用该表已获用户批准。数值是 NESdev 的 "2C02 palette"（复合视频解码后、
// 未施加强调色的）RGB 三元组。
// The table is the one used by nand2mario/nestang (GPL-3.0),
// src/nes2hdmi.sv, "2C02 palette: https://www.nesdev.org/wiki/PPU_palettes".
// Reuse of this table was approved by the user.  Values are NESdev's
// "2C02 palette" (composite-decoded, non-emphasis) RGB triples.
//
// 表项 0x0D-0x0F、0x1D-0x1F、0x2E-0x2F、0x3E-0x3F 是该表定义的黑色；
// 表项 0x00 是"通用背景色"灰 0x545454。
// Entries 0x0D-0x0F, 0x1D-0x1F, 0x2E-0x2F, 0x3E-0x3F are the blacks the table
// defines; entry 0x00 is the "universal backdrop" grey 0x545454.
//
// 强调色（$2001 的 bit 7:5）与灰度（bit 0）由 ppu_palette_shadow 捕获，
// 但*不*在此施加 —— 见 REPORT.md。
// Emphasis (bits 7:5 of $2001) and greyscale (bit 0) are captured by
// ppu_palette_shadow but are NOT applied here -- see REPORT.md.
// -----------------------------------------------------------------------------
`default_nettype none

module nes_palette (
    input  wire [5:0]  idx,
    output reg  [23:0] rgb
);

    always @(*) begin
        case (idx)
            6'd0:  rgb = 24'h545454;
            6'd1:  rgb = 24'h001e74;
            6'd2:  rgb = 24'h081090;
            6'd3:  rgb = 24'h300088;
            6'd4:  rgb = 24'h440064;
            6'd5:  rgb = 24'h5c0030;
            6'd6:  rgb = 24'h540400;
            6'd7:  rgb = 24'h3c1800;

            6'd8:  rgb = 24'h202a00;
            6'd9:  rgb = 24'h083a00;
            6'd10: rgb = 24'h004000;
            6'd11: rgb = 24'h003c00;
            6'd12: rgb = 24'h00323c;
            6'd13: rgb = 24'h000000;
            6'd14: rgb = 24'h000000;
            6'd15: rgb = 24'h000000;

            6'd16: rgb = 24'h989698;
            6'd17: rgb = 24'h084cc4;
            6'd18: rgb = 24'h3032ec;
            6'd19: rgb = 24'h5c1ee4;
            6'd20: rgb = 24'h8814b0;
            6'd21: rgb = 24'ha01464;
            6'd22: rgb = 24'h982220;
            6'd23: rgb = 24'h783c00;

            6'd24: rgb = 24'h545a00;
            6'd25: rgb = 24'h287200;
            6'd26: rgb = 24'h087c00;
            6'd27: rgb = 24'h007628;
            6'd28: rgb = 24'h006678;
            6'd29: rgb = 24'h000000;
            6'd30: rgb = 24'h000000;
            6'd31: rgb = 24'h000000;

            6'd32: rgb = 24'heceeec;
            6'd33: rgb = 24'h4c9aec;
            6'd34: rgb = 24'h787cec;
            6'd35: rgb = 24'hb062ec;
            6'd36: rgb = 24'he454ec;
            6'd37: rgb = 24'hec58b4;
            6'd38: rgb = 24'hec6a64;
            6'd39: rgb = 24'hd48820;

            6'd40: rgb = 24'ha0aa00;
            6'd41: rgb = 24'h74c400;
            6'd42: rgb = 24'h4cd020;
            6'd43: rgb = 24'h38cc6c;
            6'd44: rgb = 24'h38b4cc;
            6'd45: rgb = 24'h3c3c3c;
            6'd46: rgb = 24'h000000;
            6'd47: rgb = 24'h000000;

            6'd48: rgb = 24'heceeec;
            6'd49: rgb = 24'ha8ccec;
            6'd50: rgb = 24'hbcbcec;
            6'd51: rgb = 24'hd4b2ec;
            6'd52: rgb = 24'hecaeec;
            6'd53: rgb = 24'hecaed4;
            6'd54: rgb = 24'hecb4b0;
            6'd55: rgb = 24'he4c490;

            6'd56: rgb = 24'hccd278;
            6'd57: rgb = 24'hb4de78;
            6'd58: rgb = 24'ha8e290;
            6'd59: rgb = 24'h98e2b4;
            6'd60: rgb = 24'ha0d6e4;
            6'd61: rgb = 24'ha0a2a0;
            6'd62: rgb = 24'h000000;
            6'd63: rgb = 24'h000000;

            default: rgb = 24'h000000;
        endcase
    end

endmodule

`default_nettype wire
