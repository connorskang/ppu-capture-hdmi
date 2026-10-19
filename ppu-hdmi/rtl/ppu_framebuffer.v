// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_framebuffer.v
//
// 256 x 240 x 6 位单缓冲帧存储，共 61440 个表项。
// 256 x 240 x 6-bit single-buffer frame store, 61440 entries.
//   368,640 个数据位 = 45 KiByte。
//   368,640 data bits = 45 KiByte.
//
// 写端口：PPU 像素时钟域（clk_wr）。
// Write port : PPU pixel-clock domain (clk_wr).
// 读端口：视频像素时钟域（clk_rd），读延迟一个寄存器。
// Read  port : video pixel clock domain (clk_rd), one register of read latency.
//
// 两个端口使用不同的时钟，因此意图是让高云推断出一块半双端口 BSRAM
// （读写时钟独立）。没有地址仲裁：读侧预期显示的是之前已经完整写入的一帧
// （或者容忍撕裂，这是使用单缓冲的已知后果 —— 见 REPORT.md）。
// The two ports use different clocks, so the intent is that Gowin infers one
// semi-dual-port BSRAM (independent read/write clocks).  There is no address
// arbitration: the read side is expected to be showing a frame that was fully
// written earlier (or to tolerate a tear, which is a documented consequence of
// using a single buffer -- see REPORT.md).
//
// 深度正好是 256*240 而不是 2 的幂，这样 BSRAM 用量与图像尺寸成正比；
// 16 位地址空间高端的 4096 个地址就是没用到的。
// The depth is exactly 256*240 rather than a power of two so the BSRAM usage
// is proportional to the picture size; the upper 4096 addresses of the 16-bit
// address space are simply unused.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_framebuffer #(
    parameter integer DW    = 6,
    parameter integer DEPTH = 256*240
) (
    // 写端口（PPU 像素时钟）/ write port (PPU pixel clock)
    input  wire            clk_wr,
    input  wire            we,
    input  wire [15:0]     waddr,
    input  wire [DW-1:0]   wdata,

    // 读端口（视频像素时钟）/ read port (video pixel clock)
    input  wire            clk_rd,
    input  wire [15:0]     raddr,
    output reg  [DW-1:0]   rdata
);

    reg [DW-1:0] mem [0:DEPTH-1];

    always @(posedge clk_wr) begin
        if (we && (waddr < DEPTH[15:0]))
            mem[waddr] <= wdata;
    end

    always @(posedge clk_rd) begin
        rdata <= mem[raddr];
    end

endmodule

`default_nettype wire
