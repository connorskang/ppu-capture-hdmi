// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_hdmi_top.v
//
// 集成顶层： 2C02 采集转接板 -> 256x240x6 帧缓冲
//            -> 水平缩放（1:1 的 4 倍 / 4:3 的分数比）
//            -> 垂直 4 倍 + 扫描线明暗
//            -> NES 调色板 -> RGB -> TMDS -> HDMI
// Integrated top level: 2C02 capture interposer  ->  256x240x6 framebuffer
//                        ->  horizontal scaler (1:1 4x / 4:3 fractional)
//                        ->  vertical 4x + scanline shading
//                        ->  NES palette -> RGB -> TMDS -> HDMI
//
// 时钟方案（与已上板验证的 hdmi-core 构建相同）：
// Clocking (unchanged from the hardware-verified hdmi-core build):
//   27 MHz（引脚 4）--rPLL--> 371.25 MHz --CLKDIV/5--> 74.25 MHz 像素时钟
//   27 MHz (pin 4) --rPLL--> 371.25 MHz --CLKDIV/5--> 74.25 MHz pixel clock
//   1080p30 = CEA-861 2200x1125 @ 74.25 MHz
//   371.25 MHz 同时是 OSER10 的 FCLK（每 TMDS 通道 742.5 Mbit/s）。
//   371.25 MHz is also the OSER10 FCLK (742.5 Mbit/s per TMDS lane).
//
// PPU 侧的寄存器总线、EXT 总线与比较器信号全部由 PPU 点时钟
// （`ppu_pix_clk`，标称 5.369 MHz）驱动。在真实硬件上，它必须来自 2C02 的
// CLK 引脚（21.47727 MHz）四分频 —— 见 REPORT.md；本工程中所有 PPU 侧信号的
// 引脚分配都还是占位符（PLACEHOLDER）。
// The PPU-side register bus, EXT bus and comparator signals are all clocked by
// the PPU dot clock (`ppu_pix_clk`, 5.369 MHz nominal).  On hardware that must
// come from the 2C02 CLK pin (21.47727 MHz) divided by 4 -- see REPORT.md; the
// pin assignment for every PPU-side signal is a PLACEHOLDER in this project.
//
// 引脚预算：GW2AR-LV18QN88 封装只有 53 个普通 I/O。本顶层的第一个版本把
// cpu_d_in/cpu_d_out/cpu_d_oe 以及 PPU 侧同样的信号都引出，再加两个观测端口，
// 结果布局布线直接拒绝：
// PIN BUDGET: the GW2AR-LV18QN88 package has only 53 regular I/Os.  The first
// version of this top exposed cpu_d_in/cpu_d_out/cpu_d_oe and the same on the
// PPU side plus two observation ports, and P&R rejected it:
//     ERROR (PA2024): The number(73) of ports exceeds the resource limit 53 ...
// 因此两条寄存器总线都被做成*双向* 8 位总线 —— 硬件本来也就是这样（主板与
// PPU 插座之间的转接板）—— 并且不再把采集到的像素流引出去。这样设计降到
// 49 个 I/O，能够放下。
// Both register buses are therefore exposed as *bidirectional* 8-bit buses --
// which is also what the hardware actually is (an interposer between the
// motherboard and the PPU socket) -- and the captured pixel stream is not
// exported.  That brings the design to 49 I/O and it fits.
//
// 运行时模式选择：本构建使用参数 H_MODE_4_3（0 = 1:1，水平 4 倍 -> 1024x960；
// 1 = 4:3，水平 5 倍 -> 1280x960）。用物理开关需要占用一个已验证的板级引脚；
// 这里宁可不声明，也不去凭空编一个引脚号。
// Runtime mode select: this build uses the parameter H_MODE_4_3 (0 = 1:1, 4x
// horizontal -> 1024x960; 1 = 4:3, 5x horizontal -> 1280x960).  A physical
// switch would need one verified board pin; none is declared here rather than
// inventing a pin number.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_hdmi_top #(
    parameter integer H_MODE_4_3 = 0
) (
    // ---- 板级 / board ----
    input  wire        sys_clk,       // 27 MHz，引脚 4 / 27 MHz, pin 4
    input  wire        ppu_pix_clk,   // PPU 点时钟，5.369 MHz（见 REPORT.md）/ PPU dot clock, 5.369 MHz (see REPORT.md)
    input  wire        rst_n,

    // ---- CPU 侧的 PPU 寄存器总线（$2000-$3FFF 已译码）----
    // ---- CPU-side PPU register bus ($2000-$3FFF already decoded) ----
    input  wire        cpu_cs_n,
    input  wire        cpu_rw,
    input  wire [2:0]  cpu_a,
    inout  wire [7:0]  cpu_d,

    // ---- PPU 侧的寄存器总线（朝 2C02 插座）----
    // ---- PPU-side register bus (towards the 2C02 socket) ----
    output wire        ppu_cs_n,
    output wire        ppu_rw,
    output wire [2:0]  ppu_a,
    inout  wire [7:0]  ppu_d,

    // ---- PPU EXT 像素总线 + 比较器恢复的视频时序 ----
    // ---- PPU EXT pixel bus + comparator-derived video timing ----
    input  wire [3:0]  ext_i,
    input  wire        ext4_bg_sprite_i,
    input  wire        hsync_i,
    input  wire        vsync_i,
    input  wire        blank_i,

    // ---- 控制 / control ----
    input  wire        capture_en,
    input  wire        inject_req,

    // ---- HDMI ----
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    output wire [1:0]  led
);

    wire clk5;        // 371.25 MHz TMDS 位时钟 / 371.25 MHz TMDS bit clock
    wire clkpix;      // 74.25 MHz 像素时钟 / 74.25 MHz  pixel clock
    wire pll_lock;

    pll_hdmi_371 u_pll (
        .clkin (sys_clk),
        .clkout(clk5),
        .lock  (pll_lock)
    );

    CLKDIV #(.DIV_MODE(5)) u_div5 (
        .CLKOUT (clkpix),
        .HCLKIN (clk5),
        .RESETN (pll_lock),
        .CALIB  (1'b0)
    );

    // ------------------------------------------------------------------
    // PPU 采集转接板（从 ppu-capture/ 原样复用）
    // PPU capture interposer (reused verbatim from ppu-capture/)
    // ------------------------------------------------------------------
    wire [7:0] cpu_d_out_w, ppu_d_out_w;
    wire       cpu_d_oe_w,  ppu_d_oe_w;

    wire [5:0] pix_index;
    wire       pix_valid;

    // 引脚处总线是双向的；收发方向由采集模块自己的输出使能驱动。
    // The buses are bidirectional at the pins; the transceiver direction is
    // driven by the capture module's own output enables.
    assign cpu_d = cpu_d_oe_w ? cpu_d_out_w : 8'hzz;
    assign ppu_d = ppu_d_oe_w ? ppu_d_out_w : 8'hzz;

    wire [7:0] cpu_d_in_w = cpu_d;
    wire [7:0] ppu_d_in_w = ppu_d;

    ppu_capture_intercept u_capture (
        .clk                 (sys_clk),
        .rst_n               (rst_n),
        .phi2                (ppu_pix_clk),
        .cpu_cs_n            (cpu_cs_n),
        .cpu_rw              (cpu_rw),
        .cpu_a               (cpu_a),
        .cpu_d_in            (cpu_d_in_w),
        .cpu_d_out           (cpu_d_out_w),
        .cpu_d_oe            (cpu_d_oe_w),
        .ppu_cs_n            (ppu_cs_n),
        .ppu_rw              (ppu_rw),
        .ppu_a               (ppu_a),
        .ppu_d_out           (ppu_d_out_w),
        .ppu_d_oe            (ppu_d_oe_w),
        .ppu_d_in            (ppu_d_in_w),
        .ext_i               (ext_i),
        .ext4_bg_sprite_i    (ext4_bg_sprite_i),
        .hsync_i             (hsync_i),
        .vsync_i             (vsync_i),
        .blank_i             (blank_i),
        .pixel_index_o       (pix_index),
        .pixel_palette_addr_o(),
        .pixel_valid_o       (pix_valid),
        .emphasis_o          (),
        .grayscale_o         (),
        .capture_en          (capture_en),
        .inject_req          (inject_req),
        .inject_ack          (),
        .inject_busy         (),
        .inject_collision    (),
        .ctrl_shadow         (),
        .ext_out_bit_held    ()
    );

    // 一级寄存器，让帧缓冲写指针看到相对 PPU 像素时钟同步的信号（这与
    // ppu_ext_capture 对视频时序施加的那一级寄存器是同一个）。
    // One register stage so the framebuffer write pointer sees a signal that
    // is synchronous to the PPU pixel clock (this is the same register stage
    // ppu_ext_capture applies to the video timing).
    reg vsync_p;
    always @(posedge ppu_pix_clk or negedge rst_n) begin
        if (!rst_n) vsync_p <= 1'b0;
        else        vsync_p <= vsync_i;
    end

    // ------------------------------------------------------------------
    // 帧缓冲 + 缩放 + 调色板 + 时序
    // Framebuffer + scaler + palette + timing
    // ------------------------------------------------------------------
    wire [23:0] rgb;
    wire        de, hs, vs;
    wire [11:0] cx_o, cy_o;

    ppu_video_pipeline #(
        .H_ACTIVE  (12'd1920),
        .H_FP      (12'd88),
        .H_SYNC    (12'd44),
        .H_BP      (12'd148),
        .V_ACTIVE  (12'd1080),
        .V_FP      (12'd4),
        .V_SYNC    (12'd5),
        .V_BP      (12'd36)
    ) u_video (
        .clk        (clkpix),
        .rst        (~pll_lock),
        .wr_clk     (ppu_pix_clk),
        .wr_rst_n   (rst_n),
        .wr_en      (pix_valid),
        .wr_data    (pix_index),
        .wr_vsync   (vsync_p),
        .h_mode_43  (H_MODE_4_3[0]),
        .rgb        (rgb),
        .de         (de),
        .hsync      (hs),
        .vsync      (vs),
        .cx_o       (cx_o),
        .cy_o       (cy_o)
    );

    wire unused_cx = |cx_o;
    wire unused_cy = |cy_o;

    // ------------------------------------------------------------------
    // TMDS 编码 + 串行化（与已验证设计相同）
    // TMDS encode + serialise (unchanged from the verified design)
    // ------------------------------------------------------------------
    wire [9:0] enc0, enc1, enc2;

    tmds_encoder u_enc0 (.clk(clkpix), .d(rgb[7:0]),   .c0(hs),   .c1(vs),   .de(de), .q(enc0));
    tmds_encoder u_enc1 (.clk(clkpix), .d(rgb[15:8]),  .c0(1'b0), .c1(1'b0), .de(de), .q(enc1));
    tmds_encoder u_enc2 (.clk(clkpix), .d(rgb[23:16]), .c0(1'b0), .c1(1'b0), .de(de), .q(enc2));

    wire [2:0] tmds;
    wire       tmds_clk_i;

    OSER10 ser0 (
        .Q(tmds[0]),
        .D0(enc0[0]), .D1(enc0[1]), .D2(enc0[2]), .D3(enc0[3]), .D4(enc0[4]),
        .D5(enc0[5]), .D6(enc0[6]), .D7(enc0[7]), .D8(enc0[8]), .D9(enc0[9]),
        .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
    );

    OSER10 ser1 (
        .Q(tmds[1]),
        .D0(enc1[0]), .D1(enc1[1]), .D2(enc1[2]), .D3(enc1[3]), .D4(enc1[4]),
        .D5(enc1[5]), .D6(enc1[6]), .D7(enc1[7]), .D8(enc1[8]), .D9(enc1[9]),
        .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
    );

    OSER10 ser2 (
        .Q(tmds[2]),
        .D0(enc2[0]), .D1(enc2[1]), .D2(enc2[2]), .D3(enc2[3]), .D4(enc2[4]),
        .D5(enc2[5]), .D6(enc2[6]), .D7(enc2[7]), .D8(enc2[8]), .D9(enc2[9]),
        .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
    );

    OSER10 ser_clk (
        .Q(tmds_clk_i),
        .D0(1'b1), .D1(1'b1), .D2(1'b1), .D3(1'b1), .D4(1'b1),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .D9(1'b0),
        .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
    );

    ELVDS_OBUF bufs [3:0] (
        .I ({tmds_clk_i, tmds}),
        .O ({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

    reg [25:0] hb;
    always @(posedge clkpix)
        hb <= hb + 26'd1;

    assign led = ~{pll_lock, hb[25]};

endmodule

`default_nettype wire
