// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_pixel_out.v
//
// 把采集到的 EXT 像素颜色与调色板地址高位、以及调色板 RAM 影子结合起来，
// 生成该像素的 6 位 NES 调色板表项。
// Combines the captured EXT pixel colour with the palette-address high bit and
// the palette-RAM shadow to produce the 6-bit NES palette entry for the pixel.
//
//   调色板地址 = {ext4_bg_sprite, ext_pixel[3:0]}
//   palette address = {ext4_bg_sprite, ext_pixel[3:0]}
//
// ext4_bg_sprite = 0 选择背景半区（$3F00-$3F0F）；
// ext4_bg_sprite = 1 选择精灵半区（$3F10-$3F1F）。
// ext4_bg_sprite = 0 selects the background half ($3F00-$3F0F);
// ext4_bg_sprite = 1 selects the sprite half   ($3F10-$3F1F).
//
// 输出是 6 位调色板表项（即 NES 颜色索引，$00-$3F）。
// 24 位 RGB 表被有意留作可选，本轮不实现；见 REPORT.md。强调色 / 灰度由
// 调色板模块记录，可由后续 RGB 级施加。
// The output is the 6-bit palette entry (the NES colour index, $00-$3F).
// A 24-bit RGB table is intentionally left optional and is not implemented in
// this round; see REPORT.md.  Emphasis/grayscale are captured by the palette
// module and can be applied by a later RGB stage.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_pixel_out (
    input  wire [3:0] ext_pixel,
    input  wire       ext4_bg_sprite,
    input  wire [5:0] palette_data,
    input  wire       blank,

    output wire [4:0] palette_addr,
    output wire [5:0] pixel_index,
    output wire       pixel_valid
);

    assign palette_addr = {ext4_bg_sprite, ext_pixel};
    assign pixel_index  = palette_data;
    assign pixel_valid  = ~blank;

endmodule

`default_nettype wire
